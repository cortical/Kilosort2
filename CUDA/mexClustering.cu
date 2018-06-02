/*
 * Example of how to use the mxGPUArray API in a MEX file.  This example shows
 * how to write a MEX function that takes a gpuArray input and returns a
 * gpuArray output, e.g. B=mexFunction(A).
 *
 * Copyright 2012 The MathWorks, Inc.
 */
#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>
#include <math.h>
#include <stdint.h>
#include "mex.h"
#include "gpu/mxGPUArray.h"
#include <cstdlib>
#include <algorithm>
#include <iostream>
using namespace std;


//////////////////////////////////////////////////////////////////////////////////////////
__global__ void computeCost(const double *Params, const float *uproj, const float *mu, const float *W, 
        const int *ioff, const bool *iW, float *cmax){
    
  int tid, bid, Nspikes, Nfeatures, NfeatW, Nthreads, k;
  float xsum = 0.0f, Ci, lam; 
  
  Nspikes               = (int) Params[0];
  Nfeatures             = (int) Params[1];
  NfeatW                = (int) Params[4];
  Nthreads              = blockDim.x;
  lam                   = (float) Params[5];
    
  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  
  while(tid<Nspikes){
      if (iW[tid + bid*Nspikes]){
          xsum = 0.0f;
          for (k=0;k<Nfeatures;k++)
              xsum += uproj[k + Nfeatures * tid] * W[k + ioff[tid] +  NfeatW * bid];
          
          Ci = max(0.0f, xsum) + lam/mu[bid];
          
          cmax[tid + bid*Nspikes] = Ci * Ci / (1.0f + lam/(mu[bid] * mu[bid])) - lam;          
      }
      tid+= Nthreads;
  }
  
}


//////////////////////////////////////////////////////////////////////////////////////////
__global__ void bestFilter(const double *Params, const bool *iW, const float *cmax, int *id, float *cx){
    
  int tid,tind,bid, ind, Nspikes, Nfilters, Nthreads, Nblocks;
  float max_running = 0.0f; 
  
  Nspikes               = (int) Params[0];
  Nfilters              = (int) Params[2];
  Nthreads              = blockDim.x;
  Nblocks               = gridDim.x;

  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  
  tind = tid + bid * Nthreads;
  
  while (tind<Nspikes){
      max_running = 0.0f;
      id[tind] = 0;
      
      for(ind=0; ind<Nfilters; ind++)
          if (iW[tind + ind*Nspikes])
              if (cmax[tind + ind*Nspikes] > max_running){
                  id[tind] = ind;
                  max_running = cmax[tind + ind*Nspikes];
              }
              
      cx[tind] = max_running; 
      
      tind += Nblocks*Nthreads; 
  }  
}
//////////////////////////////////////////////////////////////////////////////////////////
__global__ void average_snips(const double *Params, const int *ioff, const int *id, const float *uproj, 
        const float *cmax, float *WU){
    
  int tid, bid, ind, Nspikes, Nfeatures, NfeatW;
  float xsum = 0.0f; 
  
  Nspikes               = (int) Params[0];
  Nfeatures             = (int) Params[1];
  NfeatW                = (int) Params[4];
 
  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
  
  for(ind=0; ind<Nspikes;ind++)
      if (id[ind]==bid){
          
          xsum = uproj[tid + Nfeatures * ind];
          WU[tid + ioff[ind] + NfeatW * bid] +=  xsum;
          
      }  
}

//////////////////////////////////////////////////////////////////////////////////////////
__global__ void count_spikes(const double *Params, const int *id, int *nsp, const float *x, float *V){
    
  int tid, tind, bid, ind, Nspikes, Nfilters, Nthreads, Nblocks;
  
  Nspikes               = (int) Params[0];
  Nfilters             = (int) Params[2];
  
  tid 		= threadIdx.x;
  bid 		= blockIdx.x;
   Nthreads              = blockDim.x;
  Nblocks               = gridDim.x;
  
  tind = tid + Nthreads *bid;
  
  while (tind<Nfilters){
      for(ind=0; ind<Nspikes;ind++)
          if (id[ind]==tind){
              nsp[tind] ++;
              V[tind] += x[tind];
          }
      V[tind] = V[tind] / (.001f + (float) nsp[tind]);
      
      tind += Nthreads * Nblocks;
  }
  
  
}


//////////////////////////////////////////////////////////////////////////////////////////

/*
 * Host code
 */
void mexFunction(int nlhs, mxArray *plhs[],
                 int nrhs, mxArray const *prhs[])
{
    /* Declare input variables*/
  double *Params, *d_Params;
  int Nfeatures, Nspikes, Nfilters;
  
  /* Initialize the MathWorks GPU API. */
  mxInitGPU();

  /* read Params and copy to GPU */
  Params                = (double*) mxGetData(prhs[0]);
  Nspikes               = (int) Params[0];
  Nfeatures             = (int) Params[1];
  Nfilters              = (int) Params[2];
  
  // copy Params to GPU
  cudaMalloc(&d_Params,      sizeof(double)*mxGetNumberOfElements(prhs[0]));
  cudaMemcpy(d_Params,Params,sizeof(double)*mxGetNumberOfElements(prhs[0]),cudaMemcpyHostToDevice);
  
  /* collect input GPU variables*/
  mxGPUArray const  *W, *uproj, *ioff, *iW, *mu;
  const float *d_W, *d_uproj, *d_mu;
  const int *d_ioff;
  const bool *d_iW;
  float *d_dWU;
    
  // these come as const GPU Arrays, just transfer them over
  uproj         = mxGPUCreateFromMxArray(prhs[1]);
  W             = mxGPUCreateFromMxArray(prhs[2]);
  ioff          = mxGPUCreateFromMxArray(prhs[3]);  
  iW            = mxGPUCreateFromMxArray(prhs[4]);
  mu            = mxGPUCreateFromMxArray(prhs[6]);

  d_uproj       = (float const *)(mxGPUGetDataReadOnly(uproj));
  d_W        	= (float const *)(mxGPUGetDataReadOnly(W));
  d_ioff        = (int const *)  (mxGPUGetDataReadOnly(ioff));
    // this has a one for filter - spike combinations to be considered
  d_iW          = (bool const *)  (mxGPUGetDataReadOnly(iW));
  d_mu          = (float const *)  (mxGPUGetDataReadOnly(mu));

  // dWU is not a constant , so the data has to be "copied" over
  mxGPUArray *dWU;
  dWU       = mxGPUCopyFromMxArray(prhs[5]);
  d_dWU     = (float *)(mxGPUGetData(dWU));  
  
  /* Define new GPU variables*/
  float *d_cmax,  *d_x, *d_V;
  int *d_id, *d_nsp;
  
  // allocate a lot of GPU variables
  cudaMalloc(&d_cmax,    Nspikes * Nfilters *  sizeof(float));
  cudaMalloc(&d_id,      Nspikes  *  sizeof(int));
  cudaMalloc(&d_x,      Nspikes  *  sizeof(float));
  cudaMalloc(&d_nsp,      Nfilters  *  sizeof(int));
   cudaMalloc(&d_V,      Nfilters  *  sizeof(float));
   
  cudaMemset(d_nsp,      0, Nfilters *   sizeof(int));
  
  // get list of cmaxes for each combination of neuron and filter
  computeCost<<<Nfilters, 1024>>>(d_Params, d_uproj, d_mu, d_W, d_ioff, 
          d_iW, d_cmax);

  // loop through cmax to find best template
  bestFilter<<<40, 256>>>(d_Params, d_iW, d_cmax, d_id, d_x);
  
  // average all spikes for same template
  average_snips<<<Nfilters, Nfeatures>>>(d_Params, d_ioff, d_id, d_uproj, 
          d_cmax, d_dWU);
  
  count_spikes<<<7, 256>>>(d_Params, d_id, d_nsp, d_x, d_V);

  // dWU stays a GPU array
  plhs[0] 	= mxGPUCreateMxArrayOnGPU(dWU);
  
  // put these ones on the CPU side: id, cmax, cf, nsp 
  int *id, *nsp;
  float *x, *V;
  
  const mwSize dimst[]      = {Nspikes,1};  
  const mwSize dimst2[] 	= {Nspikes,Nfilters};  
  const mwSize dimst4[] 	= {Nfilters,1};  

  plhs[1]   = mxCreateNumericArray(2, dimst,  mxINT32_CLASS,  mxREAL);
  plhs[2]   = mxCreateNumericArray(2, dimst, mxSINGLE_CLASS, mxREAL);  
  plhs[3]   = mxCreateNumericArray(2, dimst4, mxINT32_CLASS,  mxREAL);  
  plhs[4]   = mxCreateNumericArray(2, dimst4, mxSINGLE_CLASS, mxREAL);  

  id        = (int*) mxGetData(plhs[1]);  
  x        = (float*) mxGetData(plhs[2]);  
  nsp       = (int*) mxGetData(plhs[3]);  
  V        = (float*) mxGetData(plhs[4]);  
  
  cudaMemcpy(id,   d_id,  Nspikes * sizeof(int),   cudaMemcpyDeviceToHost);
  cudaMemcpy(x, d_x,Nspikes * sizeof(float),  cudaMemcpyDeviceToHost);
  cudaMemcpy(nsp,  d_nsp, Nfilters * sizeof(int),   cudaMemcpyDeviceToHost);
  cudaMemcpy(V, d_V, Nfilters * sizeof(float),  cudaMemcpyDeviceToHost);
  
  //we are done, clear everything from the GPU
  cudaFree(d_Params);
  cudaFree(d_cmax);
  cudaFree(d_x);
  cudaFree(d_V);
  cudaFree(d_id);
  cudaFree(d_nsp);
  

  //do this for the constant variables
  mxGPUDestroyGPUArray(uproj);
  mxGPUDestroyGPUArray(dWU);  
  mxGPUDestroyGPUArray(W);    
  mxGPUDestroyGPUArray(ioff);  
  mxGPUDestroyGPUArray(iW);  
  mxGPUDestroyGPUArray(mu);  

  
}
