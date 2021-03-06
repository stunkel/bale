/******************************************************************
//
//
//  Copyright(C) 2020, Institute for Defense Analyses
//  4850 Mark Center Drive, Alexandria, VA; 703-845-2500
//
//  All rights reserved.
//  
//  This file is a part of Bale.  For license information see the
//  LICENSE file in the top level directory of the distribution.
// 
 *****************************************************************/

/*! \file sssp_delta_conveyor.upc
 * \brief Implementation of delta stepping using convey
 */

#include "sssp.h"
#include "sssp_delta_common.h"

/*!
 * \brief Forwards the relax requests from the convey buffers to the local relax routine
 * \param ds the delta-stepping struct 
 * \param *conv the conveyor
 * \param done the signal to convey_advance that this thread is done
 * \return the return value from convey_advance
 */
static int64_t delta_convey_relax_process(ds_t *ds, convey_t *conv, int64_t done) 
{
  sssp_pkg_t pkg;

  while(convey_pull(conv, &pkg, NULL)==convey_OK){
    local_relax(ds, pkg.lj, pkg.tw);
  }
  return( convey_advance(conv, done) );
}

/*!
 * \brief Push the potentially improved weight to the thread handling the head of the edge
 * \param conv the extack buffers
 * \param ds pointer to the delta-stepping struct to be passed thru to delta_convey_relax_process
 * \param J the head of the edge, given by it global name
 * \param tw the new weight
 * \return the value from the push
 */
static int64_t delta_convey_push(convey_t *conv, ds_t *ds, int64_t J, double tw)
{
  int64_t ret, pe;
  sssp_pkg_t pkg;
  pe     = J % THREADS;
  pkg.lj = J / THREADS;
  pkg.tw = tw;
  if((ret = convey_push(conv, &pkg, pe)) == 0){
    delta_convey_relax_process(ds, conv, 0);
  }
  return(ret);
}
 
/*!
\brief The conveyor implementation of delta-stepping
\param dist the array that holds the minimum weight for each vertex
\param mat the matrix that holds the graph
\param r0 the staring node
\param opt_delta the delta given by the driver program
\return the average time for this version
*/
double sssp_delta_convey(d_array_t *dist, sparsemat_t * mat, int64_t r0, double opt_delta)
{
  int64_t i, i_m, k;
  int64_t v;
  int64_t J, pe;
  sssp_pkg_t pkg;


  convey_t * conv = convey_new(SIZE_MAX, 0, NULL, 0);
  if(conv == NULL){return(-1.0);}
  double tm = wall_seconds();

  assert((r0 >= 0) && (r0<mat->numrows));
  
  double delta;
  int64_t num_buckets;
  calculate_delta_and_num_buckets(&delta, &num_buckets, mat, opt_delta);

  ds_t * ds = (ds_t *)calloc(1,sizeof(ds_t)); assert(ds != NULL);
  allocate_and_initialize_delta_stepping_struct(ds, mat->lnumrows, num_buckets, delta);

  if( (r0 % THREADS) == MYTHREAD) {    // set the distance to r0 (as a global index) equal to 0.0
    r0 = r0/THREADS;
    ds->tent[r0] = 0.0;
    insert_node_in_bucket(ds, r0, 0);
  }
  lgp_barrier();

  int64_t grmb = 0;    // the global real min bucket (collectively the min non-empty bucket)
                       // we use this to handle the problem of min bucket (mod num_buckets)
  int64_t all_i = 0;
  int64_t start = 0;
  int64_t end = 0;

  // MAIN LOOP: exists when all buckets are empty
  while(1){
    for(i = 0; i < ds->num_buckets; i++){          // find the local min (done mod num_buckets) non-empty bucket 
      if(ds->B[(grmb + i) % ds->num_buckets] != -1)
        break;
    }
    all_i = lgp_reduce_min_l(i);                   // global min index
    if(all_i == num_buckets)                       // All buckets are empty, we are done
        break;
    grmb = grmb + all_i;
    i_m = grmb % ds->num_buckets;

    start = 0;
    end = 0;
    while( lgp_reduce_max_l(ds->B[i_m]) > -1){    // repeatly check that B[i_m] on all threads are empty
      convey_begin(conv, sizeof(sssp_pkg_t), 0);

      while( ds->B[i_m] >= 0 ) {                  // removes vertices from this bucket, but the relaxation process
                                                  // may add vertices to this bucket on any thread
        v = ds->B[i_m]; 
        remove_node_from_bucket(ds, v);

        for(k = mat->loffset[v]; k < mat->loffset[v + 1]; k++){        // relax light edges from v 
          if(mat->lvalue[k] <= delta){	  
            if(delta_convey_push(conv, ds, mat->lnonzero[k],  ds->tent[v] + mat->lvalue[k]) == 0)
              k--;
           // global_index_to_pe_and_offset(&pe, &(pkg.lj), mat->lnonzero[k], mat->numrows, CYCLIC);
           // pkg.tw = ds->tent[v] + mat->lvalue[k];
           // if( convey_push(conv, &pkg, pe) != convey_OK ) {
           //   delta_convey_relax_process(ds, conv, 0);
           //   k--;
           // }
          }
        } 
        if(ds->deleted[v] == 0){  // insert v into R if it is not already there
          ds->deleted[v] = 1;
          ds->R[end++] = v;
        }
      }
      while( delta_convey_relax_process(ds, conv, 1)) 
        ;
      lgp_barrier();
      convey_reset(conv);
    }
    lgp_barrier();

    convey_begin(conv, sizeof(sssp_pkg_t), 0);
    for(start=0; start<end; start++){           // relax heavy requests edges for everything in R 
      v = ds->R[start];
      for(k = mat->loffset[v]; k < mat->loffset[v + 1]; k++){
        if(mat->lvalue[k] > delta){	  
          if(delta_convey_push(conv, ds, mat->lnonzero[k],  ds->tent[v] + mat->lvalue[k]) == 0)
            k--;
        }
    //      global_index_to_pe_and_offset(&pe, &(pkg.lj), mat->lnonzero[k], mat->numrows, CYCLIC);
    //      pkg.tw = ds->tent[v] + mat->lvalue[k];
    //      if( convey_push(conv, &pkg, pe) != convey_OK ) {
    //        delta_convey_relax_process(ds, conv, 0);
    //        k--;
    //      }
      }
    }
    while( delta_convey_relax_process(ds, conv, 1) )
      ;
    lgp_barrier();
    convey_reset(conv); // Does convey_reset imply barriers?
    lgp_barrier();
  }

  lgp_barrier();
  for(v = 0; v < mat->lnumrows; v++){              //Copy the answers to dist array
    dist->lentry[v] = ds->tent[v];
  }

  clear_ds_struct(ds); free(ds);
  
  return(wall_seconds() - tm);
}
