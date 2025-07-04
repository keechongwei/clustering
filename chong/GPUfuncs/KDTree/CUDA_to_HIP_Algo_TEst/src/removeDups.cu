//
//  removeDups.cu
//
//  Created by John Robinson on 7/15/15.
//  Copyright (c) 2015 John Robinson. All rights reserved.
/*
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors
 *    may be used to endorse or promote products derived from this software without
 *    specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSEARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */
//

/*
 * The duplicate removal algorithm uses an approach based on the following
 * "Efficient Stream Compaction on Wide SIMD Many-Core Architectures"
 * by Markus Billeter, Ola Olsson, Ulf Assarsson
 * http://www.cse.chalmers.se/~uffe/streamcompaction.pdf
 */

#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <iomanip>
using std::setprecision;
using namespace std;
#include <assert.h>
#include <hip/hip_runtime.h>

#include "Gpu.h"
#include "removeDups_common.h"
#include "HipErrorCheck.h"

__device__ sint superKeyCompareFirstDimSmplA(const KdCoord ap, const KdCoord bp, const KdCoord *a, const KdCoord *b, const sint p, const sint dim)
{
	sint diff = ap - bp;
	for (sint i = 1; diff == 0 && i < dim; i++) {
		sint r = i + p;
		r = (r < dim) ? r : r - dim;
		diff = a[r] - b[r];
	}
	return diff;
}

/*
 * Check the validity of the merge sort and remove duplicates from a reference array.
 *
 * calling parameters:
 *
 * reference - a vector<int*> that represents one of the reference arrays
 * i - the leading dimension for the super key
 * dim - the number of dimensions
 *
 * returns: the end index of the reference array following removal of duplicate elements
 */
__device__ void cuWarpCopyRefVal(refIdx_t refout[], KdCoord valout[], refIdx_t refin[], KdCoord valin[],
		sint segSize, const sint numTuples) {


	uint pos = blockIdx.x * blockDim.x + threadIdx.x;
	uint thrdIdx = (pos & (warpSize-1));

	for (sint j = 0;  j+thrdIdx < segSize; j += warpSize){
		valout[j+thrdIdx] = valin[j+thrdIdx];
		refout[j+thrdIdx] = refin[j+thrdIdx];
	}

}

__device__ uint d_removeDupsCount;  	// This is where number of tuples after the dups are removed is returned.
__device__ sint  d_removeDupsError;  	// This is where an error is indicated.
__device__ sint  d_removeDupsErrorAdr;  // This is where number of tuples after the dups are removed is returned.

__global__ void cuRemoveGaps(refIdx_t refoutx[], KdCoord valoutx[], refIdx_t refinx[], KdCoord valinx[],
		uint segSizex, uint segLengths[], const sint numTuples) {
	uint pos = blockIdx.x * blockDim.x + threadIdx.x;
	uint thrdIdx = (pos & (warpSize-1));
	uint warpIndex = ((pos - thrdIdx)/warpSize);
	uint segStartOut = 0;
	uint segStartIn = warpIndex * segSizex;
	uint segSize = 0;

	// Do the simple slow implementation first
	// Get the seg start and seg size from the segLentghs array written by the
	if (thrdIdx == 0) {
		for (uint i = 0;  i<warpIndex; i++)
			segStartOut += segLengths[i];
		segSize = segLengths[warpIndex];
	}

	// Copy to the other threads in the warp.
	segStartOut = __shfl(segStartOut, 0);
	segSize = __shfl(segSize, 0);
	// and do the copy.
	cuWarpCopyRefVal(refoutx+segStartOut, valoutx+segStartOut, refinx+segStartIn, valinx+segStartIn, segSize, numTuples);

	// if this warp is processing the last segment, store the final size
	if (thrdIdx == 0 && ((segStartIn + segSizex) >= numTuples))
		d_removeDupsCount = segStartOut + segLengths[warpIndex];
}

__global__ void cuCopyRefVal(refIdx_t refoutx[], KdCoord valoutx[], refIdx_t refinx[], KdCoord valinx[],
		sint segSizex, const sint numTuples) {


	uint pos = blockIdx.x * blockDim.x + threadIdx.x;
	uint thrdIdx = (pos & (warpSize-1));
	//    uint warpsPerBlock = (SHARED_SIZE_LIMIT/(2*warpSize));
	uint warpIndex = ((pos - thrdIdx)/warpSize);
	uint segSize;

	// Calculate the base addrs of the global memory input and output arrays.
	uint segStart = warpIndex * segSizex;
	if (segStart + segSizex > numTuples) {
		segSize = numTuples - segStart;
	} else segSize = segSizex;

	cuWarpCopyRefVal(refoutx + segStart,  valoutx + segStart, refinx + segStart, valinx + segStart, segSize, numTuples);
}


__global__ void cuRemoveDups(KdCoord coords[], refIdx_t refoutx[], KdCoord valoutx[], refIdx_t refinx[], KdCoord valinx[],
		KdCoord otherCoords[], refIdx_t *otherRef,
		const int p, const int dim, uint segSizex, uint segLengths[], const sint numTuples)
{
	uint pos = blockIdx.x * blockDim.x + threadIdx.x;
	uint thrdIdx = (pos & (warpSize-1));
	uint warpsPerBlock = (SHARED_SIZE_LIMIT/(2*warpSize));
	uint warpIndex = ((pos - thrdIdx)/warpSize);
	KdCoord val;
	uint   ref;
	uint segSize;

	// Calculate the base addrs of the global memory input and output arrays.
	uint segStart = warpIndex * segSizex;
	if (segStart + segSizex > numTuples) {
		segSize = numTuples - segStart;
	} else segSize = segSizex;

	refIdx_t* refin = refinx + segStart;
	KdCoord*  valin = valinx + segStart;
	refIdx_t* refout = refoutx + segStart;
	KdCoord*  valout = valoutx + segStart;

	// Allocate the shared memory that will be used for coalescing of writes.
	__shared__ KdCoord  s_val[SHARED_SIZE_LIMIT];
	__shared__ refIdx_t s_ref[SHARED_SIZE_LIMIT];
	uint   outCnt = 0;
	uint oldOutCnt;

	// Calculate the base index for this warp in the shared memory array
	// SHARED_SIZE_LIMIT/(2*warpSize) is the number of warps per block
	// So the warp in block index is the mod of warpIndex by the num warps in block.
	uint sharedBase = 2 * warpSize *  (warpIndex % warpsPerBlock);
	uint sharedAddrMask = (2*warpSize)-1;

	sint  cmp = 0;
	uint maskGEme = ((1 << thrdIdx) - 1);
	uint shflMask = 0;
	//  First handle the special conditions for the initial 32 words
	// This needs be a loop to handle the case where the first warps worth of data are all equal.
	sint j;
	for (j = 0;  j < segSize && shflMask == 0; j += warpSize){
		if (thrdIdx < segSize) { // only read and compare less than segsize
			s_val[sharedBase + thrdIdx] = val = valin[thrdIdx];
			s_ref[sharedBase + thrdIdx] = ref = refin[thrdIdx];

			if (thrdIdx !=0 ) { // If not the first thread, do a normal compare with shared memory
				cmp = superKeyCompareFirstDimSmplA(val, s_val[sharedBase + thrdIdx - 1], coords+ref*dim, coords+s_ref[sharedBase + thrdIdx - 1]*dim,
						p, dim);
			} else if (warpIndex != 0) { // If first tread but not the first segment, compare with last value of previous segment.
				cmp = superKeyCompareFirstDimSmplA(val, *(valin-1), coords+ref*dim, coords+(*(refin-1))*dim,
						p, dim);
			} else if (otherCoords != NULL) { // First thread of first segment of second GPU needs to compare itself with highest word of the other GPU.
				cmp = superKeyCompareFirstDimSmplA(val, *(otherCoords+(*otherRef)*dim), coords+ref*dim, otherCoords+(*otherRef)*dim,
						p, dim);
			} else { // This handles the case of the very first data word.
				cmp = 1;  // Indicate the first value is greater so that it is always included
			}
		} else {
			cmp = 0; // Use cmp == 0 in this case to exclude data outside the range
		}
		// First check for compare failure which is earlier value is gt current
		if (cmp<0) {
			d_removeDupsError = -1;
			atomicMin(&d_removeDupsErrorAdr, (valin - valinx)  + thrdIdx);
		}
		valin += warpSize;
		refin += warpSize;

		// Check for duplicates,  a 1 in the shflMask indicates that this tread is not a dup so keep it.
		shflMask = __ballot(cmp>0);
		if (cmp > 0) {
			// Calculate the address which is determined by the number of non-dups less than this thread.
			uint wrtIdx = __popc(shflMask & maskGEme);
			s_val[sharedBase + ((outCnt + wrtIdx) & sharedAddrMask)] = val;
			s_ref[sharedBase + ((outCnt + wrtIdx) & sharedAddrMask)] = ref;
		}
	}
	// Update the output counter but keep an old value so it's known where to write the output.
	oldOutCnt = outCnt;
	outCnt += __popc(shflMask);
	// If the first read filled the buffer than write it out.
	if (((oldOutCnt ^ outCnt) & warpSize) != 0) {
		valout[(oldOutCnt & ~(warpSize-1)) + thrdIdx] = s_val[sharedBase + (oldOutCnt & warpSize) + thrdIdx];
		refout[(oldOutCnt & ~(warpSize-1)) + thrdIdx] = s_ref[sharedBase + (oldOutCnt & warpSize) + thrdIdx];
	}

	// OK, first iteration is all done,  Now start the deterministic
	for (;  j < segSize; j += warpSize){
		if (j+thrdIdx < segSize) {
			s_val[sharedBase + ((outCnt + thrdIdx) & sharedAddrMask)] = val = valin[thrdIdx];
			s_ref[sharedBase + ((outCnt + thrdIdx) & sharedAddrMask)] = ref = refin[thrdIdx];

			// Do the compare
			cmp = superKeyCompareFirstDimSmplA(val, s_val[sharedBase + ((outCnt + thrdIdx - 1) & sharedAddrMask)],
					coords+ref*dim, coords+s_ref[sharedBase + ((outCnt + thrdIdx - 1) & sharedAddrMask)]*dim,
					p, dim);
		} else {
			cmp = 0;
		}
		// First check for compare failure which is earlier value is gt current
		if (cmp<0) {
			d_removeDupsError = -1;
			atomicMin(&d_removeDupsErrorAdr, (valin - valinx)  + thrdIdx);
		}

		valin += warpSize;
		refin += warpSize;

		// Check for duplicates,  a 1 in the shflMask indicates that this tread is not a dup so keep it.
		shflMask = __ballot(cmp>0);
		if (cmp > 0) {
			// Calculate the address which is determined by the number of non dups less than this thread.
			uint wrtIdx = __popc(shflMask & maskGEme);
			s_val[sharedBase + ((outCnt + wrtIdx) & sharedAddrMask)] = val;
			s_ref[sharedBase + ((outCnt + wrtIdx) & sharedAddrMask)] = ref;
		}
		// Update the output counter but keep an old value so it's known where to write the output.
		oldOutCnt = outCnt;
		outCnt += __popc(shflMask);
		// If the write spilled into the other buffer in shared memory write buffer indicated by old count.
		if (((oldOutCnt ^ outCnt) & warpSize) != 0) {
			valout[(oldOutCnt & ~(warpSize-1)) + thrdIdx] = s_val[sharedBase + (oldOutCnt & warpSize) + thrdIdx];
			refout[(oldOutCnt & ~(warpSize-1)) + thrdIdx] = s_ref[sharedBase + (oldOutCnt & warpSize) + thrdIdx];
		}
	}
	// Write out the final buffer
	if ((outCnt & (warpSize-1)) > thrdIdx) {
		valout[(outCnt & ~(warpSize-1)) + thrdIdx] = s_val[sharedBase + (outCnt & warpSize) + thrdIdx];
		refout[(outCnt & ~(warpSize-1)) + thrdIdx] = s_ref[sharedBase + (outCnt & warpSize) + thrdIdx];
	}

	// And finally store the number of writes that were done by this warp
	if (thrdIdx == 0 && segLengths != NULL) segLengths[warpIndex] = outCnt;
}


uint Gpu::copyRefVal(KdCoord valout[], refIdx_t refout[], KdCoord valin[], refIdx_t refin[], uint numTuples, sint numThreads) {

	sint numBlocks;
	sint numThrdPerBlk;
	// This section just allows for single block execution for easier debug.
	if (numThreads >= SHARED_SIZE_LIMIT/2) {
		numBlocks = numThreads/(SHARED_SIZE_LIMIT/2);
		numThrdPerBlk = SHARED_SIZE_LIMIT/2;
	} else {
		numBlocks = 1;
		numThrdPerBlk = numThreads;
	}

	sint segSize = (numTuples + (numThreads/32) - 1) / (numThreads/32);

#pragma omp critical (launchLock)
	{
		setDevice();
		cuCopyRefVal<<<numBlocks, numThrdPerBlk, 0, stream>>>(refout, valout, refin, valin, segSize, numTuples);
		HIP_CHECK(hipGetLastError());
	}
	return 0;
}

uint Gpu::removeDups(KdCoord coords[], KdCoord val[], refIdx_t ref[], KdCoord valtmp[], refIdx_t reftmp[],
		KdCoord valin[], refIdx_t refin[], KdCoord otherCoord[], refIdx_t *otherRef,
		const sint p, const sint dim, const sint  numTuples, sint numThreads) {

	sint numBlocks;
	sint numThrdPerBlk;
	// This section just allows for single block execution for easier debug.
	if (numThreads >= SHARED_SIZE_LIMIT/2) {
		numBlocks = numThreads/(SHARED_SIZE_LIMIT/2);
		numThrdPerBlk = SHARED_SIZE_LIMIT/2;
	} else {
		numBlocks = 1;
		numThrdPerBlk = numThreads;
	}

	// Make sure the segmentSize * segments is gt than numTuples so that nothing gets missed.
	sint segSize = (numTuples + (numThreads/32) - 1) / (numThreads/32);

	uint* d_segLengths;

	//#define PRINT_TIME
#ifdef PRINT_TIME
	float time;
	hipEvent_t t_start, t_stop;
	HIP_CHECK(hipEventCreate(&t_start));
	HIP_CHECK(hipEventCreate(&t_stop));

	HIP_CHECK(hipDeviceSynchronize());
	HIP_CHECK(hipEventRecord(t_start));
#endif
	// Clear the error flag and address
	uint removeDupsError = 0;
	uint removeDupsErrorAdr = 0x7FFFFFFF;
	HIP_CHECK(hipMemcpyToSymbolAsync(d_removeDupsError,    &removeDupsError,    sizeof(d_removeDupsError), 0, hipMemcpyHostToDevice, stream));
	HIP_CHECK(hipMemcpyToSymbolAsync(d_removeDupsErrorAdr, &removeDupsErrorAdr, sizeof(d_removeDupsError), 0, hipMemcpyHostToDevice, stream));

#pragma omp critical (launchLock)
	{
		setDevice();
		HIP_CHECK(hipMalloc((void **)&d_segLengths, numThreads/32 * sizeof(uint)));
		cuRemoveDups<<<numBlocks, numThrdPerBlk>>>(coords, reftmp, valtmp, refin, valin, otherCoord, otherRef,
				p, dim, segSize, d_segLengths, numTuples);
	}
	HIP_CHECK(hipGetLastError());
#pragma omp critical (launchLock)
	{
		setDevice();
		cuRemoveGaps<<<numBlocks, numThrdPerBlk>>>(ref, val, reftmp, valtmp, segSize, d_segLengths, numTuples);
		HIP_CHECK(hipGetLastError());
	}

#ifdef PRINT_TIME
	HIP_CHECK(hipDeviceSynchronize());
	HIP_CHECK(hipEventRecord(t_stop));
	HIP_CHECK(hipEventSynchronize(t_stop));
	HIP_CHECK(hipEventElapsedTime(&time, t_start, t_stop));
	printf ("removeDups took %f seconds\n",time/1000.0);
	HIP_CHECK(hipEventDestroy(t_start));
	HIP_CHECK(hipEventDestroy(t_stop));
#endif

	// Check to see if any sort errors were detected
	HIP_CHECK(hipMemcpyFromSymbolAsync(&removeDupsError, d_removeDupsError, sizeof(d_removeDupsError), 0, hipMemcpyDeviceToHost, stream));
	if (removeDupsError != 0) {
		cout << "Remove Duplicates found a sorting error on dimension " << p  << endl;
		HIP_CHECK(hipMemcpyFromSymbolAsync(&removeDupsErrorAdr, d_removeDupsErrorAdr, sizeof(d_removeDupsErrorAdr), 0, hipMemcpyDeviceToHost, stream));
		cout << "at address  " << removeDupsErrorAdr << endl;
		return removeDupsError;
	}
	// If not return the resulting count.
	uint removeDupsCount;
	HIP_CHECK(hipMemcpyFromSymbolAsync(&removeDupsCount, d_removeDupsCount, sizeof(d_removeDupsCount), 0, hipMemcpyDeviceToHost, stream));
	return removeDupsCount;
}
