#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)
#define COHERENT_GRID 1

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
thrust::device_ptr<glm::vec3> dev_thrust_particlePosIndices;
thrust::device_ptr<glm::vec3> dev_thrust_particleVelIndices;
int *dev_particleGridIndicesPosSort;
int *dev_particleGridIndicesVelSort;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

__global__ void kernResetIntBuffer(int N, int *intBuffer, int value);
__global__ void kernResetIndexBuffer(int N, int *intBuffer);

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");
  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");
  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");
  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  kernResetIndexBuffer<<<fullBlocksPerGrid, blockSize>>>(N, dev_particleArrayIndices);
  checkCUDAErrorWithLine("kernResetIndexBuffer at init failed!");

  cudaMalloc((void**)&dev_particleGridIndicesPosSort, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndicesPosSort failed!");
  cudaMalloc((void**)&dev_particleGridIndicesVelSort, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndicesVelSort failed!");

  cudaThreadSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaThreadSynchronize();
}


/******************
* stepSimulation *
******************/

__device__ glm::vec3 kernUpdateVelocityRule1(int N, int iSelf, const glm::vec3 *pos)
{
	glm::vec3 rule1(0.0f, 0.0f, 0.0f);
	int count = 0;
	for (int i = 0; i < N; ++i)
	{
		if (i == iSelf) continue;
		if (glm::length(pos[iSelf] - pos[i]) < rule1Distance)
		{
			rule1 += pos[i];
			count++;
		}
	}

	if (count != 0) rule1 /= count;
	rule1 = (rule1 - pos[iSelf]) * rule1Scale;

	return rule1;
}

__device__ glm::vec3 kernUpdateVelocityRule2(int N, int iSelf, const glm::vec3 *pos)
{
	glm::vec3 rule2(0.0f, 0.0f, 0.0f);
	for (int i = 0; i < N; ++i)
	{
		if (i == iSelf) continue;
		if (glm::length(pos[iSelf] - pos[i]) < rule2Distance)
		{
			rule2 = rule2 - (pos[i] - pos[iSelf]);
		}
	}

	rule2 *= rule2Scale;

	return rule2;
}

__device__ glm::vec3 kernUpdateVelocityRule3(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel)
{
	glm::vec3 rule3(0.0f, 0.0f, 0.0f);
	int count = 0;
	for (int i = 0; i < N; ++i)
	{
		if (i == iSelf) continue;
		if (glm::length(pos[iSelf] - pos[i]) < rule3Distance)
		{
			rule3 += vel[i];
			count++;
		}
	}
	//if (count != 0) rule3 /= count;
	rule3 = rule3 * rule3Scale; // (rule3 - vel[iSelf])
	return rule3;
}

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
  // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
  // Rule 2: boids try to stay a distance d away from each other
  // Rule 3: boids try to match the speed of surrounding boids
	glm::vec3 vel_change(0.0f, 0.0f, 0.0f);

	vel_change += kernUpdateVelocityRule1(N, iSelf, pos);
	vel_change += kernUpdateVelocityRule2(N, iSelf, pos);
	vel_change += kernUpdateVelocityRule3(N, iSelf, pos, vel);

	vel_change += vel[iSelf];
	// restrict to max velocity.
	if (glm::length(vel_change) > maxSpeed)
	{
		vel_change = vel_change * (maxSpeed / glm::length(vel_change));
	}
	return vel_change;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  // Clamp the speed
  // Record the new velocity into vel2. Question: why NOT vel1?

	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	if (index >= N)
	{
		return;
	}

	vel2[index] = computeVelocityChange(N, index, pos, vel1);
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // TODO-2.1
    // - Label each boid with the index of its grid cell.
    // - Set up a parallel array of integer indices as pointers to the actual
    //   boid data in pos and vel1/vel2
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N)
	{
#if COHERENT_GRID
		indices[index] = index;
		int boid_index = index;
#else
		if (indices[index] < 0) indices[index] = index;
		int boid_index = indices[index];
#endif
		// Find 3D index of the cell holding this boid.
		int x = (pos[boid_index].x - gridMin.x) * inverseCellWidth;
		int y = (pos[boid_index].y - gridMin.y) * inverseCellWidth;
		int z = (pos[boid_index].z - gridMin.z) * inverseCellWidth;

		// Get 1D index
		int cell_index = gridIndex3Dto1D(x, y, z, gridResolution);

		// Update indices
		gridIndices[index] = cell_index;

		//printf("boid %d x %d y %d z %d cell %d\n", boid_index, x, y, z, cell_index);
	}

}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernResetIndexBuffer(int N, int *indexBuffer)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N)
	{
		indexBuffer[index] = index;
	}
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N)
	{
		if (index == 0 || particleGridIndices[index] != particleGridIndices[index - 1])
		{
			// If boid is the one on the beginning of grid, or the beginning of another cell.
			gridCellStartIndices[particleGridIndices[index]] = index;
		}
		if (index == (N - 1) || particleGridIndices[index] != particleGridIndices[index + 1])
		{
			// If boid is the one on the end of grid, or the end of this cell.
			gridCellEndIndices[particleGridIndices[index]] = index + 1;
		}
	}
}

__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2

	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	int gridCellCount = gridResolution * gridResolution * gridResolution;
	if (index < N)
	{
		// Find 3D index of the cell holding this boid.
		int boid_index = particleArrayIndices[index];

		int x = (pos[boid_index].x - gridMin.x) * inverseCellWidth;
		int y = (pos[boid_index].y - gridMin.y) * inverseCellWidth;
		int z = (pos[boid_index].z - gridMin.z) * inverseCellWidth;

		// Get 1D index
		int cell_index = gridIndex3Dto1D(x, y, z, gridResolution);

		// find the neighbor cells.
		// Test if the index of that boid is on the left or right side of its cell.
		bool cell_x = std::fmod(pos[boid_index].x - gridMin.x, cellWidth) > (cellWidth / 2);
		bool cell_y = std::fmod(pos[boid_index].y - gridMin.y, cellWidth) > (cellWidth / 2);
		bool cell_z = std::fmod(pos[boid_index].z - gridMin.z, cellWidth) > (cellWidth / 2);

		//printf("boid: %d x %d y %d z %d\n", boid_index, cell_x, cell_y, cell_z);

		int neighbor_cell[8] = {cell_index, cell_index, cell_index, cell_index, cell_index, cell_index, cell_index, cell_index};
		for (int i = 0; i < 8; ++i)
		{
			if (i >= 4)
			{
				if (cell_x) neighbor_cell[i]++;
				else neighbor_cell[i]--;
			}

			if (i == 2 || i == 3 || i == 7 || i == 6)
			{
				if (cell_y) neighbor_cell[i] += gridResolution;
				else neighbor_cell[i] -= gridResolution;
			}

			if (i == 1 || i == 3 || i == 5 || i == 7)
			{
				if (cell_z) neighbor_cell[i] += gridResolution * gridResolution;
				else neighbor_cell[i] -= gridResolution * gridResolution;
			}
		}

		//printf("self: %d, neighbor: %d, %d, %d, %d, %d, %d, %d, %d\n", cell_index, neighbor_cell[0], neighbor_cell[1], neighbor_cell[2], 
		//	neighbor_cell[3], neighbor_cell[4], neighbor_cell[5], neighbor_cell[6], neighbor_cell[7]);

		int base_x = cell_x ? x : x - 1;
		int base_y = cell_y ? y : y - 1;
		int base_z = cell_z ? z : z - 1;
		int neighbor_cell_vec[8];
		int tmp_index{ 0 };
		for (int i = 0; i < 2; i++)
		{
			for (int j = 0; j < 2; j++)
			{
				for (int k = 0; k < 2; k++)
				{
					int neighbor_z = base_z + i;
					int neighbor_y = base_y + j;
					int neighbor_x = base_x + k;
					if (neighbor_x < 0 || neighbor_x >= gridResolution ||
						neighbor_y < 0 || neighbor_y >= gridResolution ||
						neighbor_z < 0 || neighbor_z >= gridResolution) continue;
					neighbor_cell_vec[tmp_index++] = gridIndex3Dto1D(neighbor_x, neighbor_y, neighbor_z, gridResolution);
				}
			}
		}

		while (tmp_index < 8) neighbor_cell_vec[tmp_index++] = -1;

		//printf("self: %d, neighbor: %d, %d, %d, %d, %d, %d, %d, %d and %d %d %d %d %d %d %d %d\n", cell_index, neighbor_cell[0], neighbor_cell[1], neighbor_cell[2],
		//	neighbor_cell[3], neighbor_cell[4], neighbor_cell[5], neighbor_cell[6], neighbor_cell[7],
		//	neighbor_cell_vec[0], neighbor_cell_vec[1], neighbor_cell_vec[2], neighbor_cell_vec[3], 
		//	neighbor_cell_vec[4], neighbor_cell_vec[5], neighbor_cell_vec[6], neighbor_cell_vec[7]);



		// for each cell, first check if it contains any boids, then check accordingly.
		glm::vec3 vel_change(0.0f, 0.0f, 0.0f);
		glm::vec3 rule1(0.0f, 0.0f, 0.0f);
		glm::vec3 rule2(0.0f, 0.0f, 0.0f);
		glm::vec3 rule3(0.0f, 0.0f, 0.0f);
		int rule1_count{ 0 };
		int rule3_count{ 0 };

		for (int i = 0; i < 8; ++i)
		{
			int neighbor_cell_index = neighbor_cell_vec[i];
			if (neighbor_cell_index < 0) continue;

			//if (neighbor_cell_index == cell_index && boid_index == 12)
			//{
			//	printf("cell %d start %d end %d\n", neighbor_cell_index,
			//		gridCellStartIndices[neighbor_cell_index], gridCellEndIndices[neighbor_cell_index]);
			//}
			//if (boid_index == 12) printf("all cell %d start %d end %d\n", neighbor_cell_index, gridCellStartIndices[neighbor_cell_index], gridCellEndIndices[neighbor_cell_index]);
			if (gridCellEndIndices[neighbor_cell_index] > gridCellStartIndices[neighbor_cell_index] && gridCellStartIndices[neighbor_cell_index] > 0)
			{
				//if (boid_index == 12) printf("cell %d start %d end %d\n", neighbor_cell_index, gridCellStartIndices[neighbor_cell_index], gridCellEndIndices[neighbor_cell_index]);
				// this cell contains boids
				for (int j = gridCellStartIndices[neighbor_cell_index]; j < gridCellEndIndices[neighbor_cell_index]; ++j)
				{
					int neighbor_index = particleArrayIndices[j];
					if (neighbor_index == boid_index) continue;
					//printf("cell %d has boid %d near boid %d start_ind %d end_ind %d\n", cell_index, j, boid_index, gridCellStartIndices[cell_index], gridCellEndIndices[cell_index]);
					float length = glm::length(pos[boid_index] - pos[neighbor_index]);
					// rule1
					if (length < rule1Distance)
					{
						rule1 += pos[neighbor_index];
						rule1_count++;
						//if (boid_index == 12)
						//{
						//	printf("%d to %d this (%f, %f, %f) that (%f, %f, %f) dist %f cell %d %d\n", boid_index, neighbor_index,
						//		pos[boid_index].x, pos[boid_index].y, pos[boid_index].z,
						//		pos[neighbor_index].x, pos[neighbor_index].y, pos[neighbor_index].z, glm::distance(pos[boid_index], pos[neighbor_index]), 
						//		cell_index, neighbor_cell_index);
						//}
					}
					// rule2
					if (length < rule2Distance)
					{
						rule2 = rule2 - (pos[neighbor_index] - pos[boid_index]);
					}
					// rule3
					if (length < rule3Distance)
					{
						rule3 += vel1[neighbor_index];
						rule3_count++;
					}
				}
			}
		}

		// check globally nearest
		//if (boid_index == 12)
		//{
		//	for (int i = 0; i < N; ++i)
		//	{
		//		if (i == boid_index) continue;
		//		float dist = glm::distance(pos[boid_index], pos[i]);
		//		if (dist < rule1Distance)
		//		{
		//			int x = (pos[i].x - gridMin.x) * inverseCellWidth;
		//			int y = (pos[i].y - gridMin.y) * inverseCellWidth;
		//			int z = (pos[i].z - gridMin.z) * inverseCellWidth;

		//			// Get 1D index
		//			int neighbor_cell_index = gridIndex3Dto1D(x, y, z, gridResolution);

		//			printf("Global %d to %d this (%f, %f, %f) that (%f, %f, %f) -> (%d, %d, %d) dist %f cell %d %d\n", boid_index, i,
		//				pos[boid_index].x, pos[boid_index].y, pos[boid_index].z,
		//				pos[i].x, pos[i].y, pos[i].z, 
		//				x, y, z, dist,
		//				cell_index, neighbor_cell_index);
		//			//printf("x %f gridMin.x %f inverse %f %f %f", pos[i].x, gridMin.x, inverseCellWidth,
		//			//	(pos[i].x - gridMin.x), (pos[i].x - gridMin.x) * inverseCellWidth);
		//		}
		//	}
		//}

		if (rule1_count != 0) rule1 /= rule1_count;
		rule1 = (rule1 - pos[boid_index]) * rule1Scale;
		rule2 *= rule2Scale;
		//if (rule3_count != 0) rule3 /= rule3_count;
		rule3 *= rule3Scale;

		vel_change += rule1;
		vel_change += rule2;
		vel_change += rule3;

		vel_change += vel1[boid_index];
		// restrict to max velocity.
		if (glm::length(vel_change) > maxSpeed)
		{
			vel_change = vel_change * (maxSpeed / glm::length(vel_change));
		}

		vel2[boid_index] = vel_change;
	}

}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
	int boid_index = (blockIdx.x * blockDim.x) + threadIdx.x;
	int gridCellCount = gridResolution * gridResolution * gridResolution;
	if (boid_index < N)
	{
		// Find 3D index of the cell holding this boid.
		int x = (pos[boid_index].x - gridMin.x) * inverseCellWidth;
		int y = (pos[boid_index].y - gridMin.y) * inverseCellWidth;
		int z = (pos[boid_index].z - gridMin.z) * inverseCellWidth;

		// Get 1D index
		int cell_index = gridIndex3Dto1D(x, y, z, gridResolution);

		// find the neighbor cells.
		// Test if the index of that boid is on the left or right side of its cell.
		bool cell_x = std::fmod(pos[boid_index].x - gridMin.x, cellWidth) > (cellWidth / 2);
		bool cell_y = std::fmod(pos[boid_index].y - gridMin.y, cellWidth) > (cellWidth / 2);
		bool cell_z = std::fmod(pos[boid_index].z - gridMin.z, cellWidth) > (cellWidth / 2);

		int base_x = cell_x ? x : x - 1;
		int base_y = cell_y ? y : y - 1;
		int base_z = cell_z ? z : z - 1;
		int neighbor_cell_vec[8];
		int tmp_index{ 0 };
		// outter loop the largest loop (z * gridresolution^2), thus sequential access of boids.
		for (int i = 0; i < 2; i++)
		{
			for (int j = 0; j < 2; j++)
			{
				for (int k = 0; k < 2; k++)
				{
					int neighbor_z = base_z + i;
					int neighbor_y = base_y + j;
					int neighbor_x = base_x + k;
					if (neighbor_x < 0 || neighbor_x >= gridResolution ||
						neighbor_y < 0 || neighbor_y >= gridResolution ||
						neighbor_z < 0 || neighbor_z >= gridResolution) continue;
					neighbor_cell_vec[tmp_index++] = gridIndex3Dto1D(neighbor_x, neighbor_y, neighbor_z, gridResolution);
				}
			}
		}

		while (tmp_index < 8) neighbor_cell_vec[tmp_index++] = -1;

		// for each cell, first check if it contains any boids, then check accordingly.
		glm::vec3 vel_change(0.0f, 0.0f, 0.0f);
		glm::vec3 rule1(0.0f, 0.0f, 0.0f);
		glm::vec3 rule2(0.0f, 0.0f, 0.0f);
		glm::vec3 rule3(0.0f, 0.0f, 0.0f);
		int rule1_count{ 0 };
		int rule3_count{ 0 };

		for (int i = 0; i < 8; ++i)
		{
			int neighbor_cell_index = neighbor_cell_vec[i];
			if (neighbor_cell_index < 0) continue;

			//if (boid_index == 8)
			//{
			//	printf("cell %d start %d end %d\n", neighbor_cell_index,
			//		gridCellStartIndices[neighbor_cell_index], gridCellEndIndices[neighbor_cell_index]);
			//}


			if (gridCellEndIndices[neighbor_cell_index] > gridCellStartIndices[neighbor_cell_index] && gridCellStartIndices[neighbor_cell_index] > 0)
			{
				// this cell contains boids
				for (int j = gridCellStartIndices[neighbor_cell_index]; j < gridCellEndIndices[neighbor_cell_index]; ++j)
				{
					int neighbor_index = j;
					if (neighbor_index == boid_index) continue;

					float length = glm::length(pos[boid_index] - pos[neighbor_index]);
					// rule1
					if (length < rule1Distance)
					{
						rule1 += pos[neighbor_index];
						rule1_count++;
						//if (boid_index == 8)
						//{
						//	printf("%d to %d this (%f, %f, %f) that (%f, %f, %f) dist %f cell %d %d\n", boid_index, neighbor_index,
						//		pos[boid_index].x, pos[boid_index].y, pos[boid_index].z,
						//		pos[neighbor_index].x, pos[neighbor_index].y, pos[neighbor_index].z, glm::distance(pos[boid_index], pos[neighbor_index]), 
						//		cell_index, neighbor_cell_index);
						//}

					}
					// rule2
					if (length < rule2Distance)
					{
						rule2 = rule2 - (pos[neighbor_index] - pos[boid_index]);
					}
					// rule3
					if (length < rule3Distance)
					{
						rule3 += vel1[neighbor_index];
						rule3_count++;
					}
				}
			}
		}


		// check globally nearest
		//if (boid_index == 8)
		//{
		//	for (int i = 0; i < N; ++i)
		//	{
		//		if (i == boid_index) continue;
		//		float dist = glm::distance(pos[boid_index], pos[i]);
		//		if (dist < rule1Distance)
		//		{
		//			int x = (pos[i].x - gridMin.x) * inverseCellWidth;
		//			int y = (pos[i].y - gridMin.y) * inverseCellWidth;
		//			int z = (pos[i].z - gridMin.z) * inverseCellWidth;

		//			// Get 1D index
		//			int neighbor_cell_index = gridIndex3Dto1D(x, y, z, gridResolution);

		//			printf("Global %d to %d this (%f, %f, %f) that (%f, %f, %f) -> (%d, %d, %d) dist %f cell %d %d\n", boid_index, i,
		//				pos[boid_index].x, pos[boid_index].y, pos[boid_index].z,
		//				pos[i].x, pos[i].y, pos[i].z, 
		//				x, y, z, dist,
		//				cell_index, neighbor_cell_index);
		//			//printf("x %f gridMin.x %f inverse %f %f %f", pos[i].x, gridMin.x, inverseCellWidth,
		//			//	(pos[i].x - gridMin.x), (pos[i].x - gridMin.x) * inverseCellWidth);
		//		}
		//	}
		//}

		if (rule1_count != 0) rule1 /= rule1_count;
		rule1 = (rule1 - pos[boid_index]) * rule1Scale;
		rule2 *= rule2Scale;
		//if (rule3_count != 0) rule3 /= rule3_count;
		rule3 *= rule3Scale;

		vel_change += rule1;
		vel_change += rule2;
		vel_change += rule3;

		vel_change += vel1[boid_index];
		// restrict to max velocity.
		if (glm::length(vel_change) > maxSpeed)
		{
			vel_change = vel_change * (maxSpeed / glm::length(vel_change));
		}

		vel2[boid_index] = vel_change;
	}
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
  // TODO-1.2 ping-pong the velocity buffers

	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

	kernUpdateVelocityBruteForce << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, dev_vel1, dev_vel2);
	kernUpdatePos << <fullBlocksPerGrid, blockSize >> >(numObjects, dt, dev_pos, dev_vel2);

	glm::vec3* tmp_pt = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = tmp_pt;
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	dim3 fullBlocksPerGridCell((gridCellCount + blockSize - 1) / blockSize);
	//kernResetIndexBuffer << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_particleArrayIndices);
	//checkCUDAErrorWithLine("kernResetIndexBuffer failed!");

	//kernResetIntBuffer<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_particleGridIndices, -1);
	//checkCUDAErrorWithLine("kernResetIntBuffer failed!");

	kernResetIntBuffer<<<fullBlocksPerGridCell, blockSize>>>(gridCellCount, dev_gridCellStartIndices, -1);
	kernResetIntBuffer<<<fullBlocksPerGridCell, blockSize>>>(gridCellCount, dev_gridCellEndIndices, -1);

	kernComputeIndices<<<fullBlocksPerGrid, blockSize>>>(numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
		dev_particleArrayIndices, dev_particleGridIndices);
	checkCUDAErrorWithLine("kernComputeIndices failed!");

	dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		dev_thrust_particleArrayIndices);

	//int *intKeys = new int[numObjects];
	//int *intValues = new int[numObjects];

	//cudaMemcpy(intKeys, dev_particleArrayIndices, numObjects * sizeof(int), cudaMemcpyDeviceToHost);
	//cudaMemcpy(intValues, dev_particleGridIndices, numObjects * sizeof(int), cudaMemcpyDeviceToHost);

	//checkCUDAErrorWithLine("cuda mem cpy test sort failed!");

	//for (int i = 0; i < numObjects; ++i)
	//{
	//	std::cout << "index: " << i << " key: " << intKeys[i] << " value: " << intValues[i] << std::endl;
	//}

	kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> >(numObjects, 
		dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

	kernUpdateVelNeighborSearchScattered<<<fullBlocksPerGrid, blockSize>>>(numObjects, gridSideCount, 
		gridMinimum, gridInverseCellWidth, gridCellWidth,
		dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
	checkCUDAErrorWithLine("kernUpdateVelNeighborSearchScattered failed!");

	kernUpdatePos<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
	checkCUDAErrorWithLine("kernUpdatePos failed!");

	glm::vec3* tmp_pt = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = tmp_pt;
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
	dim3 fullBlocksPerGridCell((gridCellCount + blockSize - 1) / blockSize);

	kernResetIntBuffer << <fullBlocksPerGridCell, blockSize >> >(gridCellCount, dev_gridCellStartIndices, -1);
	kernResetIntBuffer << <fullBlocksPerGridCell, blockSize >> >(gridCellCount, dev_gridCellEndIndices, -1);

	kernComputeIndices << <fullBlocksPerGrid, blockSize >> >(numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
		dev_particleArrayIndices, dev_particleGridIndices);
	checkCUDAErrorWithLine("kernComputeIndices failed!");

	//const int testSize = 10;
	//int* testVec = new int[testSize];

	//if (numObjects == testSize)
	//{
	//	cudaMemcpy(testVec, dev_particleGridIndices, testSize * sizeof(int), cudaMemcpyDeviceToHost);
	//	printf("Test grid unsort: %d %d %d %d %d %d %d %d %d %d\n", testVec[0], testVec[1], testVec[2], testVec[3], testVec[4],
	//		testVec[5], testVec[6], testVec[7], testVec[8], testVec[9]);
	//}

	// prepare for the sorting of position and velocity.
	cudaMemcpy(dev_particleGridIndicesPosSort, dev_particleGridIndices, numObjects * sizeof(int), cudaMemcpyDeviceToDevice);
	cudaMemcpy(dev_particleGridIndicesVelSort, dev_particleGridIndices, numObjects * sizeof(int), cudaMemcpyDeviceToDevice);

	//glm::vec3* testGlmVec = new glm::vec3[testSize];
	//if (numObjects == testSize)
	//{
	//	cudaMemcpy(testGlmVec, dev_pos, testSize * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	//	printf("Test pos unsort: %f %f %f %f %f %f %f %f %f %f\n", testGlmVec[0].x, testGlmVec[1].x, testGlmVec[2].x, testGlmVec[3].x, testGlmVec[4].x,
	//		testGlmVec[5].x, testGlmVec[6].x, testGlmVec[7].x, testGlmVec[8].x, testGlmVec[9].x);
	//}
	//if (numObjects == testSize)
	//{
	//	cudaMemcpy(testGlmVec, dev_vel1, testSize * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	//	printf("Test vel unsort: %f %f %f %f %f %f %f %f %f %f\n", testGlmVec[0].x, testGlmVec[1].x, testGlmVec[2].x, testGlmVec[3].x, testGlmVec[4].x,
	//		testGlmVec[5].x, testGlmVec[6].x, testGlmVec[7].x, testGlmVec[8].x, testGlmVec[9].x);
	//}

	dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		dev_thrust_particleArrayIndices);
	//if (numObjects == testSize)
	//{
	//	cudaMemcpy(testVec, dev_particleGridIndices, testSize * sizeof(int), cudaMemcpyDeviceToHost);
	//	printf("Test grid sort: %d %d %d %d %d %d %d %d %d %d\n", testVec[0], testVec[1], testVec[2], testVec[3], testVec[4],
	//		testVec[5], testVec[6], testVec[7], testVec[8], testVec[9]);
	//}

	// Sort pos and vel array to rearrange boids.
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndicesPosSort);
	dev_thrust_particlePosIndices = thrust::device_ptr<glm::vec3>(dev_pos);
	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		dev_thrust_particlePosIndices);
	//if (numObjects == testSize)
	//{
	//	cudaMemcpy(testGlmVec, dev_pos, testSize * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	//	printf("Test pos sort: %f %f %f %f %f %f %f %f %f %f\n", testGlmVec[0].x, testGlmVec[1].x, testGlmVec[2].x, testGlmVec[3].x, testGlmVec[4].x,
	//		testGlmVec[5].x, testGlmVec[6].x, testGlmVec[7].x, testGlmVec[8].x, testGlmVec[9].x);
	//}

	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndicesVelSort);
	dev_thrust_particleVelIndices = thrust::device_ptr<glm::vec3>(dev_vel1);
	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects,
		dev_thrust_particleVelIndices);
	//if (numObjects == testSize)
	//{
	//	cudaMemcpy(testGlmVec, dev_vel1, testSize * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	//	printf("Test vel sort: %f %f %f %f %f %f %f %f %f %f\n", testGlmVec[0].x, testGlmVec[1].x, testGlmVec[2].x, testGlmVec[3].x, testGlmVec[4].x,
	//		testGlmVec[5].x, testGlmVec[6].x, testGlmVec[7].x, testGlmVec[8].x, testGlmVec[9].x);
	//}

	kernIdentifyCellStartEnd << <fullBlocksPerGrid, blockSize >> >(numObjects,
		dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	checkCUDAErrorWithLine("kernIdentifyCellStartEnd failed!");

	kernUpdateVelNeighborSearchCoherent<<<fullBlocksPerGrid, blockSize>>>(numObjects, gridSideCount, 
		gridMinimum, gridInverseCellWidth, gridCellWidth,
		dev_gridCellStartIndices, dev_gridCellEndIndices, dev_pos, dev_vel1, dev_vel2);
	checkCUDAErrorWithLine("kernUpdateVelNeighborSearchCoherent failed!");

	kernUpdatePos << <fullBlocksPerGrid, blockSize >> >(numObjects, dt, dev_pos, dev_vel2);
	checkCUDAErrorWithLine("kernUpdatePos failed!");

	glm::vec3* tmp_pt = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = tmp_pt;

}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_particleGridIndices);

  cudaFree(dev_particleGridIndicesPosSort);
  cudaFree(dev_particleGridIndicesVelSort);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  int *intKeys = new int[N];
  int *intValues = new int[N];

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys, sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues, sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys, dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues, dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  delete[] intKeys;
  delete[] intValues;
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
