// Copyright Supranational LLC

#include "../../poseidon/cuda/poseidon.cu"
#include "../../util/debug_helpers.hpp"
#include "host_ptr_t.hpp"

#ifndef __CUDA_ARCH__

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>

#include <filesystem>
#include <chrono>
#include "../planner.cpp"
#include "pc2.cuh"
#include "cuda_lambda_t.hpp"
#include "../../util/util.hpp"

template<class C>
pc2_t<C>::pc2_t(SectorParameters& _params, topology_t& _topology,
                bool _tree_r_only, streaming_node_reader_t<C>& _reader,
                size_t _nodes_to_read, size_t _batch_size,
                size_t _stream_count,
                const char** _data_filenames, const char* _output_dir) :
  params(_params),
  topology(_topology),
  tree_r_only(_tree_r_only),
  reader(_reader),
  nodes_to_read(_nodes_to_read),
  batch_size(_batch_size),
  tree_c_address(params.GetNumNodes() / params.GetNumTreeRCFiles(),
                 TREE_ARITY, NODE_SIZE, 0),
  tree_r_address(params.GetNumNodes() / params.GetNumTreeRCFiles(),
                 TREE_ARITY, NODE_SIZE, params.GetNumTreeRDiscardRows() + 1),
  stream_count(_stream_count),
  tree_c_partition_roots(C::PARALLEL_SECTORS * TREE_ARITY),
  tree_r_partition_roots(C::PARALLEL_SECTORS * TREE_ARITY),
  gpu_results_c(tree_r_only ? 0 :_batch_size * C::PARALLEL_SECTORS / TREE_ARITY * stream_count),
  gpu_results_r(_batch_size * C::PARALLEL_SECTORS / TREE_ARITY * stream_count),
  host_buf_storage(num_host_bufs * batch_size * C::PARALLEL_SECTORS),
  data_filenames(_data_filenames),
  output_dir(_output_dir)
{
  assert (TREE_ARITY == params.GetNumTreeRCArity());
  assert (nodes_to_read % stream_count == 0);

  open_files();
  
  // Compute the final offset in the file for GPU data
  const size_t cpu_nodes_to_hash = batch_size * stream_count / TREE_ARITY / TREE_ARITY;
  tree_address_t final_tree(cpu_nodes_to_hash, TREE_ARITY, sizeof(fr_t), 0);
  final_gpu_offset_c = tree_c_address.data_size() - final_tree.data_size();
  final_gpu_offset_r = tree_r_address.data_size() - final_tree.data_size();

  // Compute an offset table used for multiple partitions
  size_t nodes_per_stream = nodes_to_read / stream_count;
  size_t layer_offset = nodes_per_stream;
  while (layer_offset >= TREE_ARITY) {
    layer_offsets_c.push_back(layer_offset);
    layer_offset /= TREE_ARITY;
  }

  layer_offset = nodes_per_stream;
  for (size_t i = 0; i < params.GetNumTreeRDiscardRows() + 1; i++) {
    layer_offset /= TREE_ARITY;
  }
  while (layer_offset >= TREE_ARITY) {
    layer_offsets_r.push_back(layer_offset);
    layer_offset /= TREE_ARITY;
  }

  // Create GPU poseidon hashers and streams
  size_t resource_id = 0;
  for (size_t i = 0; i < ngpus(); i++) {
    auto& gpu = select_gpu(i);
    if (!tree_r_only) {
      poseidon_columns.push_back(new PoseidonCuda<COL_ARITY_DT>(gpu));
    }
    poseidon_trees.push_back(new PoseidonCuda<TREE_ARITY_DT>(gpu));
      
    for (size_t j = 0; j < stream_count / ngpus(); j++) {
      resources.push_back(new gpu_resource_t<C>(params,resource_id, gpu,
                                                nodes_per_stream, batch_size));
      resource_id++;
    }
  }

  // Register the SPDK page buffer with the CUDA driver
  size_t page_buffer_size = 0;
  page_buffer = (uint8_t*)reader.get_full_buffer(page_buffer_size);
  cudaHostRegister(page_buffer, page_buffer_size, cudaHostRegisterDefault);

  // Set up host side buffers for returning data
  host_bufs.resize(num_host_batches * disk_io_batch_size);
  host_batches.resize(num_host_batches + num_host_empty_batches);
  host_buf_pool_full.create(num_host_batches + num_host_empty_batches);
  host_buf_pool_empty.create(num_host_batches + num_host_empty_batches);
  host_buf_to_disk.create(num_host_batches + num_host_empty_batches);
  
  for (size_t i = 0; i < num_host_batches; i++) {
    for (size_t j = 0; j < disk_io_batch_size; j++) {
      host_batches[i].batch[j] = &host_bufs[i * disk_io_batch_size + j];
      host_batches[i].batch[j]->data =
        &host_buf_storage[i * disk_io_batch_size * batch_size * C::PARALLEL_SECTORS +
                          j * batch_size * C::PARALLEL_SECTORS];
    }
    host_buf_pool_full.enqueue(&host_batches[i]);
  }
  for (size_t i = 0; i < num_host_empty_batches; i++) {
    for (size_t j = 0; j < disk_io_batch_size; j++) {
      host_batches[i + num_host_batches].batch[j] = nullptr;
    }
    host_buf_pool_empty.enqueue(&host_batches[i + num_host_batches]);
  }
}

template<class C>
pc2_t<C>::~pc2_t() {
  while (resources.size() > 0) {
    gpu_resource_t<C>* r = resources.back();
    select_gpu(r->gpu);
      
    delete r;
    resources.pop_back();
  }
  for (size_t i = 0; i < ngpus(); i++) {
    if (!tree_r_only) {
      delete poseidon_columns[i];
    }
    delete poseidon_trees[i];
  }
  for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
    for (auto it : tree_c_files[i]) {
      delete it;
    }
    for (auto it : tree_r_files[i]) {
      delete it;
    }
  }
  cudaHostUnregister(page_buffer);
}
template<class C>
void pc2_t<C>::get_filenames(SectorParameters& params, const char* output_dir,
                             std::vector<std::string>& directories,
                             std::vector<std::string>& p_aux_filenames,
                             std::vector<std::vector<std::string>>& tree_c_filenames,
                             std::vector<std::vector<std::string>>& tree_r_filenames,
                             std::vector<std::string>& sealed_filenames) {
  // Put layer11 / sealed file in a replicas directory if it exists
  std::string pc2_replica_output_dir = output_dir;
  pc2_replica_output_dir += "/replicas";
  if (!std::filesystem::exists(pc2_replica_output_dir.c_str())) {
    pc2_replica_output_dir = output_dir;
  }

  const char* p_aux_template;
  if (C::PARALLEL_SECTORS == 1) {
    p_aux_template = "%s/p_aux";
  } else {
    p_aux_template = "%s/%03ld/p_aux";
  }
  // Open all tree-c and tree-r files
  const char* tree_c_filename_template;
  const char* tree_r_filename_template;
  if (C::PARALLEL_SECTORS == 1) {
    if (params.GetNumTreeRCFiles() > 1) {
      tree_c_filename_template = "%s/sc-02-data-tree-c-%ld.dat";
      tree_r_filename_template = "%s/sc-02-data-tree-r-last-%ld.dat";
    } else {
      tree_c_filename_template = "%s/sc-02-data-tree-c.dat";
      tree_r_filename_template = "%s/sc-02-data-tree-r-last.dat";
    }
  } else {
    if (params.GetNumTreeRCFiles() > 1) {
      tree_c_filename_template = "%s/%03ld/sc-02-data-tree-c-%ld.dat";
      tree_r_filename_template = "%s/%03ld/sc-02-data-tree-r-last-%ld.dat";
    } else {
      tree_c_filename_template = "%s/%03ld/sc-02-data-tree-c.dat";
      tree_r_filename_template = "%s/%03ld/sc-02-data-tree-r-last.dat";
    }
  }
  // And sealed files
  const char* sealed_filename_template;
  if (C::PARALLEL_SECTORS == 1) {
    sealed_filename_template = "%s/sealed-file";
  } else {
    sealed_filename_template = "%s/%03ld/sealed-file";
  }

  directories.push_back(output_dir);

  tree_c_filenames.resize(C::PARALLEL_SECTORS);
  tree_r_filenames.resize(C::PARALLEL_SECTORS);
  
  const size_t MAX = 256;
  char fname[MAX];
  for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
    // Create sector subdirs
    if (C::PARALLEL_SECTORS == 1) {
      snprintf(fname, MAX, "%s", output_dir);
    } else {
      snprintf(fname, MAX, "%s/%03ld", output_dir, i);
    }
    directories.push_back(fname);

    if (C::PARALLEL_SECTORS == 1) {
      snprintf(fname, MAX, p_aux_template, output_dir);
    } else {
      snprintf(fname, MAX, p_aux_template, output_dir, i);
    }
    p_aux_filenames.push_back(fname);

    if (C::PARALLEL_SECTORS == 1) {
      snprintf(fname, MAX, "%s", pc2_replica_output_dir.c_str());
    } else {
      snprintf(fname, MAX, "%s/%03ld", pc2_replica_output_dir.c_str(), i);
    }
    directories.push_back(fname);

    for (size_t j = 0; j < params.GetNumTreeRCFiles(); j++) {
      // tree-c
      if (C::PARALLEL_SECTORS == 1) {
        if (params.GetNumTreeRCFiles() > 1) {
          snprintf(fname, MAX, tree_c_filename_template, output_dir, j);
        } else {
          snprintf(fname, MAX, tree_c_filename_template, output_dir);
        }
      } else {
        if (params.GetNumTreeRCFiles() > 1) {
          snprintf(fname, MAX, tree_c_filename_template, output_dir, i, j);
        } else {
          snprintf(fname, MAX, tree_c_filename_template, output_dir, i);
        }
      }
      tree_c_filenames[i].push_back(fname);
                            
      // tree-r
      if (C::PARALLEL_SECTORS == 1) {
        if (params.GetNumTreeRCFiles() > 1) {
          snprintf(fname, MAX, tree_r_filename_template, output_dir, j);
        } else {
          snprintf(fname, MAX, tree_r_filename_template, output_dir);
        }
      } else {
        if (params.GetNumTreeRCFiles() > 1) {
          snprintf(fname, MAX, tree_r_filename_template, output_dir, i, j);
        } else {
          snprintf(fname, MAX, tree_r_filename_template, output_dir, i);
        }
      }
      tree_r_filenames[i].push_back(fname);
    }

    // Data files for encoding
    if (C::PARALLEL_SECTORS == 1) {
      snprintf(fname, MAX, sealed_filename_template, pc2_replica_output_dir.c_str());
   } else {
      snprintf(fname, MAX, sealed_filename_template, pc2_replica_output_dir.c_str(), i);
    }
    sealed_filenames.push_back(fname);
  }
}

template<class C>
void pc2_t<C>::open_files() {
  std::vector<std::string> directories;
  std::vector<std::vector<std::string>> tree_c_filenames;
  std::vector<std::vector<std::string>> tree_r_filenames;
  std::vector<std::string> sealed_filenames;
  
  get_filenames(params, output_dir,
                directories,
                p_aux_filenames,
                tree_c_filenames,
                tree_r_filenames,
                sealed_filenames);

  for (auto it : directories) {  
    if (!std::filesystem::exists(it)) {
      std::filesystem::create_directory(it);
    }
  }
  has_cc_sectors = false;
  has_non_cc_sectors = false;

  size_t num_tree_files = params.GetNumTreeRCFiles();
  for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
    if (!tree_r_only) {
      tree_c_files[i].resize(num_tree_files);
    }
    tree_r_files[i].resize(num_tree_files);
    for (size_t j = 0; j < num_tree_files; j++) {
      // tree-c
      if (!tree_r_only) {
        tree_c_files[i][j] = new file_writer_t<fr_t>();
        assert(tree_c_files[i][j]->open(tree_c_filenames[i][j],
                                        tree_c_address.data_size(), true, false) == 0);
        tree_c_files[i][j]->advise_random();
      }
                            
      // tree-r
      tree_r_files[i][j] = new file_writer_t<fr_t>();
      assert(tree_r_files[i][j]->open(tree_r_filenames[i][j],
                                      tree_r_address.data_size(), true, false) == 0);
      tree_r_files[i][j]->advise_random();
    }

    // Data files for encoding
    if (!tree_r_only) {
      if (data_filenames != nullptr && data_filenames[i] != nullptr) {
        data_files[i].mmap_read(data_filenames[i], SECTOR_SIZE);
        // If there is a data file present we will encode layer 11 and write the
        // sealed data
        assert(sealed_files[i].open(sealed_filenames[i], SECTOR_SIZE, true, false) == 0);
        has_non_cc_sectors = true;
      } else {
        // Write the raw layer 11 data
        // It would be nice to write different files for encoded vs not encoded data but in
        // reality we can't differentiate between CC and sectors that will use remote data.
        // So we write them all to 'sealed_data' here.
        assert(sealed_files[i].open(sealed_filenames[i], SECTOR_SIZE, true, false) == 0);
        has_cc_sectors = true;
      }
    }
  }
}

template<class C>
void pc2_t<C>::hash() {
  thread_pool_t pool(1);
  pool.spawn([&]() {
    // Affinitize the thread in the pool
    set_core_affinity(topology.pc2_hasher_cpu);
  });

  // Use a channel to prevent the GPU from racing ahead of the CPU
  channel_t<int> ch;
  ch.send(-1);

  host_buffer_t cpu_input_c(gpu_results_c.size());
  host_buffer_t cpu_input_r(gpu_results_r.size());
  
  auto start = std::chrono::high_resolution_clock::now();
  for (size_t partition = 0; partition < params.GetNumTreeRCFiles(); partition++) {
    auto pstart_gpu = std::chrono::high_resolution_clock::now();
    hash_gpu(partition);
    auto pstop_gpu = std::chrono::high_resolution_clock::now();

    gpu_results_in_use.lock();
    ch.recv();
    pool.spawn([&, partition]() {
      // Protect against a race condition for gpu_results where if the CPU hashing
      // is slow relative to the GPU the results could be overwritten before they are
      // used. 
      memcpy(&cpu_input_c[0], &gpu_results_c[0], gpu_results_c.size() * sizeof(fr_t));
      memcpy(&cpu_input_r[0], &gpu_results_r[0], gpu_results_r.size() * sizeof(fr_t));

      gpu_results_in_use.unlock();
      
      if (!tree_r_only) {
        hash_cpu(&tree_c_partition_roots[partition * C::PARALLEL_SECTORS],
                 partition, &(cpu_input_c[0]), tree_c_files, final_gpu_offset_c);
      }
      hash_cpu(&tree_r_partition_roots[partition * C::PARALLEL_SECTORS],
               partition, &(cpu_input_r[0]), tree_r_files, final_gpu_offset_r);
      ch.send(partition);
    });
    auto pstop_cpu = std::chrono::high_resolution_clock::now();
    uint64_t secs_gpu = std::chrono::duration_cast<
      std::chrono::seconds>(pstop_gpu - pstart_gpu).count();
    uint64_t secs_cpu = std::chrono::duration_cast<
      std::chrono::seconds>(pstop_cpu - pstop_gpu).count();
    printf("Partition %ld took %ld seconds (gpu %ld, cpu %ld)\n",
           partition, secs_gpu + secs_cpu, secs_gpu, secs_cpu);
  }
  ch.recv();
  write_roots(&tree_c_partition_roots[0], &tree_r_partition_roots[0]);
  auto stop = std::chrono::high_resolution_clock::now();
  uint64_t secs = std::chrono::duration_cast<
    std::chrono::seconds>(stop - start).count();

  size_t total_page_reads = nodes_to_read * params.GetNumTreeRCFiles() /
    C::NODES_PER_PAGE * params.GetNumLayers();
  printf("pc2 took %ld seconds utilizing %0.1lf iOPS\n",
         secs, (double)total_page_reads / (double)secs);
}

template<class C>
void pc2_t<C>::process_writes(int core, size_t max_write_size,
                              mtx_fifo_t<buf_to_disk_batch_t>& to_disk_fifo,
                              mtx_fifo_t<buf_to_disk_batch_t>& pool,
                              std::atomic<bool>& terminate,
                              std::atomic<int>& disk_writer_done) {
  set_core_affinity(core);
  fr_t* staging = new fr_t[max_write_size];

  size_t count = 0;
  while(!terminate || to_disk_fifo.size() > 0) {
    if (pool.is_full()) {
      continue;
    }

    buf_to_disk_batch_t* to_disk_batch = to_disk_fifo.dequeue();
    if (to_disk_batch != nullptr) {
#ifndef DISABLE_FILE_WRITES
      for (size_t batch_elmt = 0; batch_elmt < disk_io_batch_size; batch_elmt++) {
        buf_to_disk_t<C>* to_disk = to_disk_batch->batch[batch_elmt];
        if (to_disk == nullptr || to_disk->size == 0) {
          continue;
        }
        // printf("Writing batch element %ld stride %ld size %ld %p\n",
        //        batch_elmt, to_disk->stride, to_disk->size, to_disk->data);
        if (to_disk->stride == 1) {
          // Copy chunks of contiguous data
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            if (to_disk->src[i] != nullptr) {
              // printf("Writing from %p to %p offset %ld size %ld\n",
              //        to_disk->src[i], to_disk->dst[i], to_disk->offset, to_disk->size);
              to_disk->dst[i]->write_data(to_disk->offset, to_disk->src[i], to_disk->size);
            }
          }
        } else {
          //  Copy strided src data
          assert (max_write_size <= to_disk->size);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            if (to_disk->src[i] != nullptr) {
              for (size_t j = 0; j < to_disk->size; j++) {
                staging[j] = to_disk->src[i][j * to_disk->stride];
                if (to_disk->reverse) {
                  node_t *n = (node_t*)&staging[j];
                  n->reverse_l();
                }
              }
              to_disk->dst[i]->write_data(to_disk->offset, staging, to_disk->size);
            }
          }
        }
      }
#endif
      //      count++;
      pool.enqueue(to_disk_batch);
    }
  }
  delete [] staging;
  disk_writer_done--;
}

template<class C>
struct pc2_batcher_t {
  typedef typename pc2_t<C>::buf_to_disk_batch_t buf_to_disk_batch_t;

  buf_to_disk_batch_t* unbundle;
  buf_to_disk_batch_t* bundle;
  mtx_fifo_t<buf_to_disk_batch_t>& to_disk;
  mtx_fifo_t<buf_to_disk_batch_t>& pool_full;
  mtx_fifo_t<buf_to_disk_batch_t>& pool_empty;
  size_t idx_unbundle;
  size_t idx_bundle;
  std::mutex mtx;

  pc2_batcher_t(mtx_fifo_t<buf_to_disk_batch_t>& _pool_full,
                mtx_fifo_t<buf_to_disk_batch_t>& _pool_empty,
                mtx_fifo_t<buf_to_disk_batch_t>& _to_disk)
    : pool_full(_pool_full), pool_empty(_pool_empty), to_disk(_to_disk)
  {
    unbundle = pool_full.dequeue();
    bundle = pool_empty.dequeue();
    assert (unbundle != nullptr);
    assert (bundle != nullptr);
    idx_unbundle = 0;
    idx_bundle = 0;
  }
  
  ~pc2_batcher_t() {
    flush();
  }

  void flush() {
    std::unique_lock<std::mutex> lock(mtx);
    // Issue any partially bundles writes
    assert (idx_bundle == idx_unbundle);
    if (idx_bundle > 0) {
      while (idx_bundle < buf_to_disk_batch_t::BATCH_SIZE) {
        unbundle->batch[idx_unbundle]->size = 0;
        bundle->batch[idx_bundle] = unbundle->batch[idx_unbundle++];
        idx_bundle++;
        idx_unbundle++;
      }
      to_disk.enqueue(bundle);
      pool_empty.enqueue(unbundle);
    } else {
      // Untouched bundle/unbundle batches
      if (bundle != nullptr) {
        pool_empty.enqueue(bundle);
      }
      if (unbundle != nullptr) {
        pool_full.enqueue(bundle);
      }
    }
    bundle = nullptr;
    unbundle = nullptr;
    idx_unbundle = 0;
    idx_bundle = 0;
  }

  buf_to_disk_t<C>* dequeue() {
    std::unique_lock<std::mutex> lock(mtx);
    if (unbundle == nullptr) {
      unbundle = pool_full.dequeue();
      if (unbundle == nullptr) {
        return nullptr;
      }
    }
    buf_to_disk_t<C>* buf = unbundle->batch[idx_unbundle++];
    if (idx_unbundle == buf_to_disk_batch_t::BATCH_SIZE) {
      pool_empty.enqueue(unbundle);
      unbundle = nullptr;
      idx_unbundle = 0;
    }
    return buf;
  }

  bool enqueue(buf_to_disk_t<C>* buf) {
    std::unique_lock<std::mutex> lock(mtx);
    if (bundle == nullptr) {
      bundle = pool_empty.dequeue();
      if (bundle == nullptr) {
        //return false;
        assert(false);
      }
    }
    bundle->batch[idx_bundle++] = buf;
    if (idx_bundle == buf_to_disk_batch_t::BATCH_SIZE) {
      to_disk.enqueue(bundle);
      bundle = nullptr;
      idx_bundle = 0;
    }
    return true;
  }

  size_t size() {
    std::unique_lock<std::mutex> lock(mtx);
    return std::min
      (// Available buffer slots to store data
       (unbundle == nullptr ? 0 : (buf_to_disk_batch_t::BATCH_SIZE - idx_unbundle)) +
       pool_full.size() * buf_to_disk_batch_t::BATCH_SIZE,

                    // Available empty buffer slots
       (bundle == nullptr ? 0 : (buf_to_disk_batch_t::BATCH_SIZE - idx_bundle)) +
       pool_empty.size() * buf_to_disk_batch_t::BATCH_SIZE);
  }
};


template<class C>
void pc2_t<C>::hash_gpu(size_t partition) {
  assert (stream_count % ngpus() == 0);

  nodes_per_stream = nodes_to_read / stream_count;

  for (size_t i = 0; i < resources.size(); i++) {
    resources[i]->reset();
  }
  
  // Start a thread to process writes to disk
  std::atomic<bool> terminate = false;
  const size_t num_writers = (size_t)this->topology.pc2_writer_cores;
  thread_pool_t pool(num_writers);
  std::atomic<int> disk_writer_done(num_writers);
  for (size_t i = 0; i < num_writers; i++) {
    pool.spawn([this, &terminate, &disk_writer_done, i]() {
      process_writes(this->topology.pc2_writer + i, batch_size,
                     host_buf_to_disk, host_buf_pool_full,
                     terminate, disk_writer_done);
    });
  }
  pc2_batcher_t<C> disk_batcher(host_buf_pool_full, host_buf_pool_empty, host_buf_to_disk);
  
  bool all_done = false;
  cuda_lambda_t cuda_notify(1);
  in_ptrs_d<TREE_ARITY> in_d;
  buf_to_disk_t<C>* to_disk = nullptr;
  buf_to_disk_t<C>* to_disk_r = nullptr;
  fr_t* fr = nullptr;
  size_t disk_bufs_needed = 0;

  // printf("to_disk_fifo %ld, pool_full %ld, pool_empty %ld\n",
  //        host_buf_to_disk.size(), host_buf_pool_full.size(), host_buf_pool_empty.size());

  //size_t num_writes = 0;
  
  // auto start = std::chrono::high_resolution_clock::now();
  while (!all_done) {
    // auto now = std::chrono::high_resolution_clock::now();
    // uint64_t secs = std::chrono::duration_cast<
    //   std::chrono::seconds>(now - start).count();
    // if (secs > 60) {
    //   printf("to_disk_fifo %ld, pool_full %ld, pool_empty %ld\n",
    //          host_buf_to_disk.size(), host_buf_pool_full.size(), host_buf_pool_empty.size());
    //   for (size_t resource_num = 0; resource_num < resources.size(); resource_num++) {
    //     printf("resource %ld state %d\n", resource_num, (int)resources[resource_num]->state);
    //   }
    //   start = now;
    // }

    all_done = true;
    for (size_t resource_num = 0; resource_num < resources.size(); resource_num++) {
      gpu_resource_t<C>& resource = *resources[resource_num];
      select_gpu(resource.gpu);
      int gpu_id = resource.gpu.id();

      if (resource.state != ResourceState::DONE) {
        all_done = false;
      }

      fr_t* out_c_d = nullptr;
      fr_t* out_r_d = nullptr;
      size_t layer_offset;
      node_id_t addr;
      size_t offset_c;
      size_t offset_r;
      bool write_tree_r;
      bool write_tree_c;

      // Device storage for the hash result
      if (resource.work_c.buf != nullptr) {
        out_c_d = &(*resource.work_c.buf)[0];
        out_r_d = &(*resource.work_r.buf)[0];
      }

      switch (resource.state) {
      case ResourceState::DONE:
        // Nothing
        break;
        
      case ResourceState::IDLE:
        // Initiate data read
        resource.last = !resource.scheduler_c.next([](work_item_t<gpu_buffer_t>& w) {},
                                                   &resource.work_c);
        resource.scheduler_r.next([](work_item_t<gpu_buffer_t>& w) {},
                                  &resource.work_r);
        if (resource.work_c.is_leaf) {
#ifdef DISABLE_FILE_READS
          resource.state = ResourceState::HASH_COLUMN;
          resource.column_data = (fr_t*)reader.get_slot(resource.id);
#else
          resource.state = ResourceState::DATA_READ;
#endif
        } else {
          resource.state = ResourceState::HASH_LEAF;
        }
        break;

      case ResourceState::DATA_READ:
        // Initiate the next data read
        resource.start_node = (// Perform batch_size nodes in parallel
                               (uint64_t)resource.work_c.idx.node() * batch_size +
                               // Each resource (GPU stream) works on a differet nodes_per_stream chunk
                               nodes_per_stream * resource.id +
                               // Each partition is size nodes_to_read
                               partition * nodes_to_read);
        resource.column_data = (fr_t*)reader.load_layers
          (resource.id,
           tree_r_only ? params.GetNumLayers() - 1 : 0, // start layer
           resource.start_node, batch_size,
           tree_r_only ? 1 : params.GetNumLayers(), // num_layers
           &resource.valid, &resource.valid_count);
        resource.state = ResourceState::DATA_WAIT;
        break;

      case ResourceState::DATA_WAIT:
        if (resource.valid.load() == resource.valid_count) {
          if (!tree_r_only) {
            if (disk_batcher.size() < 1) {
              break;
            }
            to_disk = disk_batcher.dequeue();
            assert (to_disk != nullptr);
          }

          fr_t* encode_buf = &resource.replica_data[0];
          
          // Copy layer 11 data to to_disk buffer for encoding/writing
          // If only building tree-r then only the last layer is present
          fr_t* layer11;
          if (tree_r_only) {
            layer11 = &resource.column_data[0];
          } else {
            layer11 = &resource.column_data[C::PARALLEL_SECTORS *
                                            (params.GetNumLayers() - 1) * batch_size];
          }
          memcpy(encode_buf, layer11,
                 C::PARALLEL_SECTORS * batch_size * sizeof(fr_t));

          // Encode non CC sectors
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            if (data_files[i].is_open()) {
              for (size_t j = 0; j < batch_size; j++) {
                // Perform the field add without moving to Montgomery space
                fr_t data = data_files[i][resource.start_node + j];
                fr_t* elmt = &encode_buf[i + j * C::PARALLEL_SECTORS];
                node_t* n = (node_t*)elmt;
                if (!reader.data_is_big_endian()) {
                  n->reverse_l();
                }
                *elmt += data;
                if (!reader.data_is_big_endian()) {
                  n->reverse_l();
                }
              }
            }
          }

          if (!tree_r_only) {
            // Prepare write pointers
            to_disk->size = batch_size;
            to_disk->stride = C::PARALLEL_SECTORS;
            to_disk->reverse = true;
            to_disk->offset = resource.start_node;
            for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
              to_disk->src[i] = &to_disk->data[i];
              //to_disk->dst[i] = &sealed_files[i][resource.start_node];
              to_disk->dst[i] = &sealed_files[i];
              // printf("Initiate replica write from %p to %p offset %ld size %ld\n",
              //        to_disk->src[i], to_disk->dst[i], to_disk->offset, to_disk->size);
            }
            
            // Copy the encoded replica data into the disk buffer
            memcpy(&to_disk->data[0],
                   &resource.replica_data[0],
                   batch_size * C::PARALLEL_SECTORS * sizeof(fr_t));
          }
          
          if (tree_r_only) {
            resource.state = ResourceState::HASH_COLUMN_LEAVES;
          } else {
            assert(disk_batcher.enqueue(to_disk));
            resource.state = ResourceState::HASH_COLUMN;
          }
        }
        break;
      
      case ResourceState::HASH_COLUMN:
        if (disk_batcher.size() < 1) {
          break;
        }
        to_disk = disk_batcher.dequeue();
        assert (to_disk != nullptr);
        
        resource.stream.HtoD(&resource.column_data_d[0], resource.column_data, resource.batch_elements);

        // Hash the columns
        poseidon_columns[gpu_id]->hash_batch_device
          (out_c_d, &resource.column_data_d[0], &resource.aux_d[0],
           batch_size * C::PARALLEL_SECTORS, C::PARALLEL_SECTORS,
           resource.stream, true, false, true, true,
           !reader.data_is_big_endian());

        // Initiate copy of the hashed data from GPU
        fr = to_disk->data;
        resource.stream.DtoH(fr, out_c_d, batch_size * C::PARALLEL_SECTORS);

        // Initiate transfer of tree-c data to files
        layer_offset = layer_offsets_c[resource.work_c.idx.layer() - 1];
        addr = node_id_t(resource.work_c.idx.layer() - 1,
                         resource.work_c.idx.node() * batch_size + layer_offset * resource_num);
        offset_c = tree_c_address.address(addr);
        to_disk->size = batch_size;
        to_disk->stride = 1;
        to_disk->reverse = false;
        to_disk->offset = offset_c / sizeof(fr_t);
        for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
          //to_disk->dst[i] = (fr_t*)&tree_c_files[i][partition][offset_c];
          to_disk->dst[i] = tree_c_files[i][partition];
          to_disk->src[i] = &to_disk->data[i * batch_size];
          // printf("Initiate column write[%ld] from %p to %p offset %ld size %ld\n",
          //        i, to_disk->src[i], to_disk->dst[i], to_disk->offset, to_disk->size);
        }
        //num_writes++;
        
        resources[resource_num]->async_done = false;
        cuda_notify.schedule(resource.stream, [this, resource_num, offset_c,
                                               to_disk, &disk_batcher]() {
          assert(disk_batcher.enqueue(to_disk));
          resources[resource_num]->async_done = true;
        });

        resource.state = ResourceState::HASH_COLUMN_LEAVES;
        break;
        
      case ResourceState::HASH_COLUMN_LEAVES:
        if (!resources[resource_num]->async_done) {
          break;
        }
        if (!tree_r_only) {
          if (disk_batcher.size() < 1) {
            break;
          }
          to_disk = disk_batcher.dequeue();
          assert (to_disk != nullptr);
          
          // Hash tree-c
          poseidon_trees[gpu_id]->hash_batch_device
            (out_c_d, out_c_d, &resource.aux_d[0],
             batch_size * C::PARALLEL_SECTORS / TREE_ARITY, 1,
             resource.stream, false, false, true, true,
             !reader.data_is_big_endian());
        }

        // Hash tree-r using the replica data. If there are any non-CC
        // sectors then copy the encoded replica data over
        if (has_non_cc_sectors || tree_r_only) {
          resource.stream.HtoD
            (&resource.column_data_d[batch_size * C::PARALLEL_SECTORS * (params.GetNumLayers() - 1)],
             &resource.replica_data[0], C::PARALLEL_SECTORS * batch_size);
        }
        poseidon_trees[gpu_id]->hash_batch_device
          (out_r_d,
           &resource.column_data_d[batch_size * C::PARALLEL_SECTORS * (params.GetNumLayers() - 1)],
           &resource.aux_d[0],
           batch_size * C::PARALLEL_SECTORS / TREE_ARITY,
           C::PARALLEL_SECTORS,
           resource.stream, false, true, true, true,
           !reader.data_is_big_endian());

        if (!tree_r_only) {
          // Initiate copy of the hashed data from GPU, reusing the host side column buffer
          resource.stream.DtoH(&to_disk->data[0], out_c_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
          
          // Initiate transfer of tree-c data to files
          layer_offset = layer_offsets_c[resource.work_c.idx.layer()];
          addr = node_id_t(resource.work_c.idx.layer(),
                           resource.work_c.idx.node() * batch_size / TREE_ARITY +
                           layer_offset * resource_num);
          offset_c = tree_c_address.address(addr);
          to_disk->size = batch_size / TREE_ARITY;
          to_disk->stride = 1;
          to_disk->reverse = false;
          to_disk->offset = offset_c / sizeof(fr_t);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            to_disk->dst[i] = tree_c_files[i][partition];
            to_disk->src[i] = &to_disk->data[i * batch_size / TREE_ARITY];
            // printf("Initiate column leaf write from %p to %p offset %ld size %ld\n",
            //        to_disk->src[i], to_disk->dst[i], to_disk->offset, to_disk->size);
          }
        }
        
        resources[resource_num]->async_done = false;
        cuda_notify.schedule(resource.stream, [this, resource_num, to_disk, &disk_batcher]() {
          if (!tree_r_only) {
            assert (disk_batcher.enqueue(to_disk));
          }
          resources[resource_num]->async_done = true;
        });
        
        resource.state = ResourceState::HASH_WAIT;
        break;

      case ResourceState::HASH_LEAF:
        write_tree_c = !tree_r_only;
        write_tree_r = resource.work_r.idx.layer() > params.GetNumTreeRDiscardRows();
        disk_bufs_needed = write_tree_c + write_tree_r;
        if (disk_batcher.size() < disk_bufs_needed) {
          break;
        }
        if (resource.last && !gpu_results_in_use.try_lock()) {
          break;
        }
        if (!tree_r_only) {
          if (write_tree_c) {
            to_disk = disk_batcher.dequeue();
            assert (to_disk != nullptr);
          }
          
          // Hash tree-c
          for (size_t i = 0; i < TREE_ARITY; i++) {
            in_d.ptrs[i] = &(*resource.work_c.inputs[i])[0];
          }
          
          poseidon_trees[gpu_id]->hash_batch_device_ptrs
            (out_c_d, in_d, &resource.aux_d[0],
             batch_size * C::PARALLEL_SECTORS / TREE_ARITY,
             C::PARALLEL_SECTORS,
             resource.stream, false, false, true, true,
             !reader.data_is_big_endian());
        }
        
        // Hash tree-r 
        for (size_t i = 0; i < TREE_ARITY; i++) {
          in_d.ptrs[i] = &(*resource.work_r.inputs[i])[0];
        }
        poseidon_trees[gpu_id]->hash_batch_device_ptrs
          (out_r_d, in_d, &resource.aux_d[0],
           batch_size * C::PARALLEL_SECTORS / TREE_ARITY,
           C::PARALLEL_SECTORS,
           resource.stream, false, false, true, true,
           !reader.data_is_big_endian());
        
        if (!tree_r_only) {
          // Initiate copy of the hashed data
          resource.stream.DtoH(&to_disk->data[0], out_c_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
          if (resource.last) {
            // Stash the final result in a known place
            size_t stride = batch_size * C::PARALLEL_SECTORS / TREE_ARITY;
            fr_t* host_buf_c = (fr_t*)&gpu_results_c[resource.id * stride];
            CUDA_OK(cudaMemcpyAsync(host_buf_c, &to_disk->data[0],
                                    batch_size * C::PARALLEL_SECTORS / TREE_ARITY * sizeof(fr_t),
                                    cudaMemcpyHostToHost, resource.stream));
          }

          // Compute offsets in the output files - tree-c
          layer_offset = layer_offsets_c[resource.work_c.idx.layer()];
          addr = node_id_t(resource.work_c.idx.layer(),
                           resource.work_c.idx.node() * batch_size / TREE_ARITY +
                           layer_offset * resource_num);
          offset_c = tree_c_address.address(addr);
          to_disk->size = batch_size / TREE_ARITY;
          to_disk->stride = 1;
          to_disk->reverse = false;
          to_disk->offset = offset_c / sizeof(fr_t);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            //to_disk->dst[i] = (fr_t*)&tree_c_files[i][partition][offset_c];
            to_disk->dst[i] = tree_c_files[i][partition];
            to_disk->src[i] = &to_disk->data[i * batch_size / TREE_ARITY];
            // printf("Initiate tree-c write from %p to %p offset %ld size %ld\n",
            //        to_disk->src[i], to_disk->dst[i], to_disk->offset, to_disk->size);
          }
        }
        
        // tree-r
        if (resource.last) {
          // Stash the final result in a known place
          size_t stride = batch_size * C::PARALLEL_SECTORS / TREE_ARITY;
          fr_t* host_buf_r = (fr_t*)&gpu_results_r[resource.id * stride];
          resource.stream.DtoH(host_buf_r, out_r_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
        }

        if (write_tree_r) {
          to_disk_r = disk_batcher.dequeue();
          assert (to_disk_r != nullptr);
          resource.stream.DtoH(&to_disk_r->data[0], out_r_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
          
          layer_offset = layer_offsets_r[resource.work_r.idx.layer() - params.GetNumTreeRDiscardRows() - 1];
          addr = node_id_t(resource.work_r.idx.layer() - params.GetNumTreeRDiscardRows() - 1,
                           resource.work_r.idx.node() * batch_size / TREE_ARITY +
                           layer_offset * resource_num);
          offset_r = tree_r_address.address(addr);
          to_disk_r->size = batch_size / TREE_ARITY;
          to_disk_r->stride = 1;
          to_disk_r->reverse = false;
          to_disk_r->offset = offset_r / sizeof(fr_t);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            //to_disk_r->dst[i] = (fr_t*)&tree_r_files[i][partition][offset_r];
            to_disk_r->dst[i] = tree_r_files[i][partition];
            to_disk_r->src[i] = &to_disk_r->data[i * batch_size / TREE_ARITY];
            // printf("Initiate tree-r write from %p to %p offset %ld size %ld\n",
            //        to_disk->src[i], to_disk->dst[i], to_disk->offset, to_disk->size);
          }
        }
        
        // Initiate transfer of data to files
        resources[resource_num]->async_done = false;
        cuda_notify.schedule(resource.stream, [this, resource_num, &disk_batcher,
                                               to_disk, to_disk_r, write_tree_r, write_tree_c]() {
          if (resources[resource_num]->last) {
            gpu_results_in_use.unlock();
          }
          if (write_tree_c) {
            assert(disk_batcher.enqueue(to_disk));
          }
          if (write_tree_r) {
            assert(disk_batcher.enqueue(to_disk_r));
          }
          resources[resource_num]->async_done = true;
        });

        resource.state = ResourceState::HASH_WAIT;
        break;
      
      case ResourceState::HASH_WAIT:
        if (resource.async_done.load() == true) {
          if (resource.last) {
            resource.state = ResourceState::DONE;
          } else {
            resource.state = ResourceState::IDLE;
          }
        }
        break;

      default:
        abort();
      }
    }
  }
  for (size_t resource_num = 0; resource_num < stream_count; resource_num++) {
    resources[resource_num]->stream.sync();
  }
  disk_batcher.flush();

  terminate = true;

  // Really only need this at the last partition...
  while (disk_writer_done > 0) {}

  //printf("num_writes %ld\n", num_writes);
}

template<class C>
void pc2_t<C>::hash_cpu(fr_t* roots, size_t partition, fr_t* input,
                        std::vector<file_writer_t<fr_t>*>* tree_files,
                        size_t file_offset) {
  // This count is one layer above the leaves
  const size_t nodes_to_hash = batch_size * stream_count / TREE_ARITY / TREE_ARITY;
  // Number of consecutive nodes in the input stream
  const size_t group_size = batch_size / TREE_ARITY;
  // For simplicity of indexing require batch size to be a multiple of arity
  assert (group_size % TREE_ARITY == 0);

  tree_address_t final_tree(nodes_to_hash, TREE_ARITY, sizeof(fr_t), 0);

  Poseidon hasher(TREE_ARITY);

  auto hash_func = [this, &hasher, &final_tree, input, partition, tree_files, file_offset, group_size]
    (work_item_t<host_buffer_t>& w) {
    node_id_t addr(w.idx.layer() - 1, w.idx.node());
    size_t offset = final_tree.address(addr) + file_offset;

    if (w.is_leaf) {
      for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
        fr_t* out = &(*w.buf)[sector];
        fr_t in[TREE_ARITY];

        size_t first_input_node = w.idx.node() * TREE_ARITY;
        for (size_t i = 0; i < TREE_ARITY; i++) {
          size_t input_group   = (first_input_node + i) / group_size;
          size_t node_in_group = (first_input_node + i) % group_size;
          
          in[i] = input[input_group * group_size * C::PARALLEL_SECTORS +
                        sector * group_size + node_in_group];
        }
        hasher.Hash((uint8_t*)out, (uint8_t*)in);
        tree_files[sector][partition]->write_data(offset / sizeof(fr_t), &out[0], 1);
      }
    } else {
      for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
        fr_t* out = &(*w.buf)[sector];
        fr_t in[TREE_ARITY];
        for (size_t i = 0; i < TREE_ARITY; i++) {
          in[i] = (*w.inputs[i])[sector];
        }
        hasher.Hash((uint8_t*)out, (uint8_t*)in);
        tree_files[sector][partition]->write_data(offset / sizeof(fr_t), (fr_t*)&out[0], 1);
      }
    }
  };
  
  buffers_t<host_buffer_t> buffers(C::PARALLEL_SECTORS);
  scheduler_t<host_buffer_t> scheduler(nodes_to_hash, TREE_ARITY, buffers);
  host_buffer_t* host_buf = scheduler.run(hash_func);
  memcpy(roots, &(*host_buf)[0], sizeof(fr_t) * C::PARALLEL_SECTORS);
  assert (scheduler.is_done());
}

template<class C>
void pc2_t<C>::write_roots(fr_t* roots_c, fr_t* roots_r) {
  if (params.GetNumTreeRCFiles() > 1) {
    Poseidon hasher(TREE_ARITY);
    for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
      fr_t in[TREE_ARITY];
      fr_t out_c;
      if (!tree_r_only) {
        for (size_t i = 0; i < TREE_ARITY; i++) {
          in[i] = roots_c[i * C::PARALLEL_SECTORS + sector];
        }
        hasher.Hash((uint8_t*)&out_c, (uint8_t*)in);
      }
      
      fr_t out_r;
      for (size_t i = 0; i < TREE_ARITY; i++) {
        in[i] = roots_r[i * C::PARALLEL_SECTORS + sector];
      }
      hasher.Hash((uint8_t*)&out_r, (uint8_t*)in);
    
      int p_aux = open(p_aux_filenames[sector].c_str(), O_RDWR | O_CREAT, (mode_t)0664);
      assert (p_aux != -1);
      if (tree_r_only) {
        fr_t zero;
        zero.zero();
        assert (write(p_aux, &zero, sizeof(fr_t)) == sizeof(fr_t));
      } else {
        assert (write(p_aux, &out_c, sizeof(fr_t)) == sizeof(fr_t));
      }
      assert (write(p_aux, &out_r, sizeof(fr_t)) == sizeof(fr_t));
      close(p_aux);
    }
  } else {
    for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
      fr_t out_c = roots_c[sector];
      fr_t out_r = roots_r[sector];

      int p_aux = open(p_aux_filenames[sector].c_str(), O_RDWR | O_CREAT, (mode_t)0664);
      assert (p_aux != -1);
      if (tree_r_only) {
        fr_t zero;
        zero.zero();
        assert (write(p_aux, &zero, sizeof(fr_t)) == sizeof(fr_t));
      } else {
        assert (write(p_aux, &out_c, sizeof(fr_t)) == sizeof(fr_t));
      }
      assert (write(p_aux, &out_r, sizeof(fr_t)) == sizeof(fr_t));
      close(p_aux);
    }
  }
}

template<class C>
void pc2_hash(SectorParameters& params, topology_t& topology,
              bool tree_r_only,
              streaming_node_reader_t<C>& reader,
              size_t nodes_to_read, size_t batch_size,
              size_t stream_count,
              const char** data_filenames, const char* output_dir) {
  pc2_t<C> pc2(params, topology, tree_r_only, reader, nodes_to_read, batch_size, stream_count,
               data_filenames, output_dir);
  pc2.hash();
}

template void pc2_hash<sealing_config128_t>(SectorParameters& params, topology_t& topology,
                                            bool tree_r_only,
                                            streaming_node_reader_t<sealing_config128_t>& reader,
                                            size_t nodes_to_read, size_t batch_size,
                                            size_t stream_count,
                                            const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config64_t>(SectorParameters& params, topology_t& topology,
                                           bool tree_r_only,
                                           streaming_node_reader_t<sealing_config64_t>& reader,
                                           size_t nodes_to_read, size_t batch_size,
                                           size_t stream_count,
                                           const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config32_t>(SectorParameters& params, topology_t& topology,
                                           bool tree_r_only,
                                           streaming_node_reader_t<sealing_config32_t>& reader,
                                           size_t nodes_to_read, size_t batch_size,
                                           size_t stream_count,
                                           const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config16_t>(SectorParameters& params, topology_t& topology,
                                           bool tree_r_only,
                                           streaming_node_reader_t<sealing_config16_t>& reader,
                                           size_t nodes_to_read, size_t batch_size,
                                           size_t stream_count,
                                           const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config8_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config8_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config4_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config4_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config2_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config2_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);

template<class C>
void do_pc2_cleanup(SectorParameters& params, const char* output_dir) {
  std::vector<std::string> directories;
  std::vector<std::string> p_aux_filenames;
  std::vector<std::vector<std::string>> tree_c_filenames;
  std::vector<std::vector<std::string>> tree_r_filenames;
  std::vector<std::string> sealed_filenames;
  
  pc2_t<C>::get_filenames(params, output_dir,
                          directories,
                          p_aux_filenames,
                          tree_c_filenames,
                          tree_r_filenames,
                          sealed_filenames);

  for (auto fname : p_aux_filenames) {
    std::filesystem::remove(fname);
  }
  for (auto fname : sealed_filenames) {
    std::filesystem::remove(fname);
  }
  for (size_t i = 0; i < tree_c_filenames.size(); i++) {
    for (auto fname : tree_c_filenames[i]) {
      std::filesystem::remove(fname);
    }
  }
  for (size_t i = 0; i < tree_r_filenames.size(); i++) {
    for (auto fname : tree_r_filenames[i]) {
      std::filesystem::remove(fname);
    }
  }
}

template void do_pc2_cleanup<sealing_config128_t>(SectorParameters& params, const char* output_dir);
template void do_pc2_cleanup<sealing_config64_t>(SectorParameters& params, const char* output_dir);
template void do_pc2_cleanup<sealing_config32_t>(SectorParameters& params, const char* output_dir);
template void do_pc2_cleanup<sealing_config16_t>(SectorParameters& params, const char* output_dir);
template void do_pc2_cleanup<sealing_config8_t>(SectorParameters& params, const char* output_dir);
template void do_pc2_cleanup<sealing_config4_t>(SectorParameters& params, const char* output_dir);
template void do_pc2_cleanup<sealing_config2_t>(SectorParameters& params, const char* output_dir);
                                            
#endif
