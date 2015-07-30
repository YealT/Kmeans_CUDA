#include "KmeansCUDA.h"

#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <curand_kernel.h>

#include <iostream>

#include <stdlib.h>

#define BLOCKSIZE_16 16
#define BLOCKSIZE_32 32
#define OBJLENGTH 75

/**
* ���ܣ���ʼ��ÿ��������������
* �����objClusterIdx_Dev ÿ���������������
* ���룺objNum ��������
* ���룺maxIdx ���������ֵ
*/
__global__ void KmeansCUDA_Init_ObjClusterIdx(int *objClusterIdx_Dev, int objNum, int maxIdx)
{
	int index = blockDim.x * blockIdx.x + threadIdx.x; 

	curandState s;
	curand_init(index, 0, 0, &s);

	if (index < objNum) objClusterIdx_Dev[index] = (int(curand_uniform(&s) * maxIdx));
}


/**
* ���ܣ����� Kmeans �ľ�������
* ���룺objData_Dev ��������
* ���룺objClusterIdx_Dev ÿ���������������
* �����clusterData_Dev ��������
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_Update_Cluster(float *objData_Dev, int *objClusterIdx_Dev, float *clusterData_Dev, sParameter myParameter)
{
	int x_id = blockDim.x * blockIdx.x + threadIdx.x; // ������
	int y_id = blockDim.y * blockIdx.y + threadIdx.y; // ������
	
	if (x_id < myParameter.objLength && y_id < myParameter.objNum)
	{
		int index = y_id * myParameter.objLength + x_id;
		int clusterIdx = objClusterIdx_Dev[y_id];

		atomicAdd(&clusterData_Dev[clusterIdx * myParameter.objLength + x_id], objData_Dev[index]);
	}
}

/**
*���ܣ����� Kmeans �ľ�������
* ���룺objClusterIdx_Dev ÿ���������������
* �����objNumInCluster ÿ�������е�������
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_Count_objNumInCluster(int *objClusterIdx_Dev, int *objNumInCluster, sParameter myParameter)
{
	int index = blockDim.x * blockIdx.x + threadIdx.x;

	if (index < myParameter.objNum)
	{
		int clusterIdx = objClusterIdx_Dev[index];

		atomicAdd((int*)&objNumInCluster[clusterIdx], 1); // ����
	}
}

/**
*���ܣ����� Kmeans �ľ�������
* ���룺objClusterIdx_Dev ÿ���������������
* �����objNumInCluster ÿ�������е�������
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_Count_objNumInCluster1(int *objClusterIdx_Dev, int *objNumInCluster, sParameter myParameter)
{
	int index = blockDim.x * blockIdx.x + threadIdx.x;

	__shared__ int sData[80];

	if (threadIdx.x < myParameter.clusterNum)
		sData[threadIdx.x] = 0;

	__syncthreads();

	if (index < myParameter.objNum)
	{
		int clusterIdx = objClusterIdx_Dev[index];
		atomicAdd((int*)&sData[clusterIdx], 1);
	}

	__syncthreads();

	if (threadIdx.x < myParameter.clusterNum)
		atomicAdd((int*)&objNumInCluster[threadIdx.x], sData[threadIdx.x]); // ����
}

/**
*���ܣ�ƽ�� Kmeans �ľ�������
* �����clusterData_Dev ��������
* �����objNumInCluster ÿ�������е�������
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_Scale_Cluster(float *clusterData_Dev, int *objNumInCluster, sParameter myParameter)
{
	int x_id = blockDim.x * blockIdx.x + threadIdx.x; // ������
	int y_id = blockDim.y * blockIdx.y + threadIdx.y; // ������
	
	if (x_id < myParameter.objLength && y_id < myParameter.clusterNum)
	{
		int index = y_id * myParameter.objLength + x_id;
		clusterData_Dev[index] /= float(objNumInCluster[y_id]);
	}
}


/**
* ���ܣ���������������ŷ������
* ���룺objects ��������
* �����clusters ������������
* ���룺objLength ��������
*/
__device__ inline static float EuclidDistance(float *objects, float *clusters, int objLength)
{
	float dist = 0.0f;

	for (int i = 0; i < objLength; i++)
	{
		float onePoint = objects[i] - clusters[i];
		dist = onePoint * onePoint + dist;
	}

	return(dist);
}

/**
* ���ܣ���������������������ĵ�ŷʽ����
* ���룺objData_Dev ��������
* ���룺objClusterIdx_Dev ÿ���������������
* ���룺clusterData_Dev ��������
* �����distOfObjAndCluster_Dev ÿ��������������ĵ�ŷʽ����
* ���룺objNumInCluster_Dev ÿ�������е�������
* ���룺iter ��������
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_distOfObjAndCluster(float *objData_Dev, int *objClusterIdx_Dev, float *clusterData_Dev, float *distOfObjAndCluster_Dev, int *objNumInCluster_Dev, int iter, sParameter myParameter)
{
	int x_id = blockDim.x * blockIdx.x + threadIdx.x; // ������
	int y_id = blockDim.y * blockIdx.y + threadIdx.y; // ������

	const int oneBlockData = OBJLENGTH * BLOCKSIZE_16;
	__shared__ float objShared[oneBlockData]; // ������
	__shared__ float cluShared[oneBlockData]; // ���������

	/* ���ݶ��빲���ڴ� */
	if (y_id < myParameter.objNum)
	{
		float *objects = &objData_Dev[myParameter.objLength * blockDim.y * blockIdx.y]; // ��ǰ����Ҫ������Ӧ���׵�ַ
		float *clusters = &clusterData_Dev[myParameter.objLength * blockDim.x * blockIdx.x]; // ��ǰ����Ҫ�������Ķ�Ӧ���׵�ַ

		for (int index = BLOCKSIZE_16 * threadIdx.y + threadIdx.x; index < oneBlockData; index = BLOCKSIZE_16 * BLOCKSIZE_16 + index)
		{
			objShared[index] = objects[index];
			cluShared[index] = clusters[index];
		}

		__syncthreads();
	}

	if (x_id < myParameter.clusterNum && y_id < myParameter.objNum)
	{
		 //if (objNumInCluster_Dev[x_id] < myParameter.minObjInClusterNum && iter >= myParameter.maxKmeansIter - 2)
			// distOfObjAndCluster_Dev[y_id * myParameter.clusterNum + x_id] = 3e30;
		 //else
			 distOfObjAndCluster_Dev[y_id * myParameter.clusterNum + x_id] = EuclidDistance(&objShared[myParameter.objLength * threadIdx.y], &cluShared[myParameter.objLength * threadIdx.x], myParameter.objLength);
	}
}

/**
* ���ܣ���������������������ĵ�ŷʽ����
* ���룺objData_Dev ��������
* ���룺objClusterIdx_Dev ÿ���������������
* ���룺clusterData_Dev ��������
* �����distOfObjAndCluster_Dev ÿ��������������ĵ�ŷʽ����
* ���룺objNumInCluster_Dev ÿ�������е�������
* ���룺iter ��������
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_distOfObjAndCluster1(float *objData_Dev, int *objClusterIdx_Dev, float *clusterData_Dev, float *distOfObjAndCluster_Dev, int *objNumInCluster_Dev, int iter, sParameter myParameter)
{
	int x_id = blockDim.x * blockIdx.x + threadIdx.x; // ������
	int y_id = blockDim.y * blockIdx.y + threadIdx.y; // ������

	__shared__ float objShared[BLOCKSIZE_16][OBJLENGTH]; // ������
	__shared__ float cluShared[BLOCKSIZE_16][OBJLENGTH]; // ���������

	float *objects = &objData_Dev[myParameter.objLength * blockDim.y * blockIdx.y]; // ��ǰ����Ҫ������Ӧ���׵�ַ
	float *clusters = &clusterData_Dev[myParameter.objLength * blockDim.x * blockIdx.x]; // ��ǰ����Ҫ�������Ķ�Ӧ���׵�ַ

	/* ���ݶ��빲���ڴ� */
	if (y_id < myParameter.objNum)
	{
		for (int xidx = threadIdx.x; xidx < OBJLENGTH; xidx += BLOCKSIZE_16)
		{
			int index = myParameter.objLength * threadIdx.y + xidx;
			objShared[threadIdx.y][xidx] = objects[index];
			cluShared[threadIdx.y][xidx] = clusters[index];
		}

		__syncthreads();
	}

	if (x_id < myParameter.clusterNum && y_id < myParameter.objNum)
	{
		if (objNumInCluster_Dev[x_id] < myParameter.minObjInClusterNum && iter >= myParameter.maxKmeansIter - 2)
			distOfObjAndCluster_Dev[y_id * myParameter.clusterNum + x_id] = 3e30;
		else
			distOfObjAndCluster_Dev[y_id * myParameter.clusterNum + x_id] = EuclidDistance(objShared[threadIdx.y], cluShared[threadIdx.x], myParameter.objLength);
	}
}

/**
* ���ܣ���������������������ĵ�ŷʽ����
* �����objClusterIdx_Dev ÿ���������������
* ���룺distOfObjAndCluster_Dev ÿ��������������ĵ�ŷʽ����
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_Update_ObjClusterIdx1(int *objClusterIdx_Dev, float *distOfObjAndCluster_Dev, sParameter myParameter)
{
	int index = blockDim.x * blockIdx.x + threadIdx.x;

	if (index < myParameter.objNum)
	{
		float *objIndex = &distOfObjAndCluster_Dev[index * myParameter.clusterNum];
		int idx = 0;
		float dist = objIndex[0];

		for (int i = 1; i < myParameter.clusterNum; i++)
		{
			if (dist > objIndex[i])
			{
				dist = objIndex[i];
				idx = i;
			}
		}
		objClusterIdx_Dev[index] = idx;
	}
}

/**
* ���ܣ���������������������ĵ�ŷʽ���루�Ż���ģ�
* �����objClusterIdx_Dev ÿ���������������
* ���룺distOfObjAndCluster_Dev ÿ��������������ĵ�ŷʽ����
* ���룺myPatameter �������
*/
__global__ void KmeansCUDA_Update_ObjClusterIdx(int *objClusterIdx_Dev, float *distOfObjAndCluster_Dev, sParameter myParameter)
{
	int y_id = blockDim.y * blockIdx.y + threadIdx.y; // ������

	__shared__ float sData[BLOCKSIZE_16][BLOCKSIZE_16]; // ������������ľ���
	__shared__ int sIndx[BLOCKSIZE_16][BLOCKSIZE_16]; // �����Ӧ������

	sData[threadIdx.y][threadIdx.x] = 2e30;
	sIndx[threadIdx.y][threadIdx.x] = 0;

	__syncthreads();

	if (y_id < myParameter.objNum)
	{
		float *objIndex = &distOfObjAndCluster_Dev[y_id * myParameter.clusterNum];
		sData[threadIdx.y][threadIdx.x] = objIndex[threadIdx.x];
		sIndx[threadIdx.y][threadIdx.x] = threadIdx.x;

		__syncthreads();

		/* ÿ BLOCKSIZE_16 �����бȽ� */
		for (int index = threadIdx.x + BLOCKSIZE_16; index < myParameter.clusterNum; index += BLOCKSIZE_16)
		{
			float nextData = objIndex[index];
			if (sData[threadIdx.y][threadIdx.x] > nextData)
			{
				sData[threadIdx.y][threadIdx.x] = nextData;
				sIndx[threadIdx.y][threadIdx.x] = index;
			}
		}

		/* BLOCKSIZE_16 �����ڲ���Լ����ֻʣ 2 �� */
		for (int step = BLOCKSIZE_16 / 2; step > 1; step = step >> 1)
		{
			int idxStep = threadIdx.x + step;
			if (threadIdx.x < step && sData[threadIdx.y][threadIdx.x] > sData[threadIdx.y][idxStep])
			{
				sData[threadIdx.y][threadIdx.x] = sData[threadIdx.y][idxStep];
				sIndx[threadIdx.y][threadIdx.x] = sIndx[threadIdx.y][idxStep];
			}
			//__syncthreads();
		}

		if (threadIdx.x == 0)
		{
			objClusterIdx_Dev[y_id] = sData[threadIdx.y][0] < sData[threadIdx.y][1] ? sIndx[threadIdx.y][0] : sIndx[threadIdx.y][1];
		}
	}
}


/**
* ���ܣ����� Kmeans ����
* ���룺objData_Host ��������
* �����objClassIdx_Host ÿ���������������
* �����centerData_Host ��������
* ���룺myPatameter �������
*/
void KmeansCUDA(float *objData_Host, int *objClassIdx_Host, float*centerData_Host, sParameter myParameter)
{
	/* �����豸���ڴ� */
	float *objData_Dev, *centerData_Dev;
	cudaMalloc((void**)&objData_Dev, myParameter.objNum * myParameter.objLength * sizeof(float));
	cudaMalloc((void**)&centerData_Dev, myParameter.clusterNum * myParameter.objLength * sizeof(float));
	cudaMemcpy(objData_Dev, objData_Host, myParameter.objNum * myParameter.objLength * sizeof(float), cudaMemcpyHostToDevice);

	int *objClassIdx_Dev;
	cudaMalloc((void**)&objClassIdx_Dev, myParameter.objNum * sizeof(int));

	float *distOfObjAndCluster_Dev; // ÿ��������������ĵ�ŷʽ����
	cudaMalloc((void**)&distOfObjAndCluster_Dev, myParameter.objNum * myParameter.clusterNum * sizeof(float));

	int *objNumInCluster_Dev; // ÿ�������е�������
	cudaMalloc((void**)&objNumInCluster_Dev, myParameter.clusterNum * sizeof(int));


	/* �߳̿���̸߳� */
	dim3 dimBlock1D_16(BLOCKSIZE_16 * BLOCKSIZE_16);
	dim3 dimBlock1D_32(BLOCKSIZE_32 * BLOCKSIZE_32);
	dim3 dimGrid1D_16((myParameter.objNum + BLOCKSIZE_16 * BLOCKSIZE_16 - 1) / dimBlock1D_16.x);
	dim3 dimGrid1D_32((myParameter.objNum + BLOCKSIZE_32 * BLOCKSIZE_32 - 1) / dimBlock1D_32.x);

	dim3 dimBlock2D(BLOCKSIZE_16, BLOCKSIZE_16);
	dim3 dimGrid2D_Cluster((myParameter.objLength + BLOCKSIZE_16 - 1) / dimBlock2D.x, (myParameter.clusterNum + BLOCKSIZE_16 - 1) / dimBlock2D.y);
	dim3 dimGrid2D_ObjNum_Objlen((myParameter.objLength + BLOCKSIZE_16 - 1) / dimBlock2D.x, (myParameter.objNum + BLOCKSIZE_16 - 1) / dimBlock2D.y);
	dim3 dimGrid2D_ObjCluster((myParameter.clusterNum + BLOCKSIZE_16 - 1) / dimBlock2D.x, (myParameter.objNum + BLOCKSIZE_16 - 1) / dimBlock2D.y);
	dim3 dimGrid2D_ObjNum_BLOCKSIZE_16(1, (myParameter.objNum + BLOCKSIZE_16 - 1) / dimBlock2D.y);

	// ��¼ʱ��
	cudaEvent_t start_GPU, end_GPU;
	float elaspsedTime;
	cudaEventCreate(&start_GPU);
	cudaEventCreate(&end_GPU);
	cudaEventRecord(start_GPU, 0);

	/* �������������ĳ�ʼ��*/
	KmeansCUDA_Init_ObjClusterIdx<<<dimGrid1D_16, dimBlock1D_16>>>(objClassIdx_Dev, myParameter.objNum, myParameter.clusterNum);

	for (int i = 0; i < myParameter.maxKmeansIter; i++)
	{
		cudaMemset(centerData_Dev, 0, myParameter.clusterNum * myParameter.objLength * sizeof(float));
		cudaMemset(objNumInCluster_Dev, 0, myParameter.clusterNum * sizeof(int));

		/* ͳ��ÿһ��������� */
		KmeansCUDA_Update_Cluster<<<dimGrid2D_ObjNum_Objlen, dimBlock2D>>>(objData_Dev, objClassIdx_Dev, centerData_Dev, myParameter);

		/* ͳ��ÿһ����������� */
		//KmeansCUDA_Count_objNumInCluster1<<<dimGrid1D_16, dimBlock1D_16>>>(objClassIdx_Dev, objNumInCluster_Dev, myParameter);
		KmeansCUDA_Count_objNumInCluster<<<dimGrid1D_32, dimBlock1D_32>>>(objClassIdx_Dev, objNumInCluster_Dev, myParameter);

		/* ��������ƽ�� = ������ / �������� */
		KmeansCUDA_Scale_Cluster<<<dimGrid2D_Cluster, dimBlock2D>>>(centerData_Dev, objNumInCluster_Dev, myParameter);

		/* ����ÿ��������ÿ���������ĵ�ŷʽ���� */
		KmeansCUDA_distOfObjAndCluster<<<dimGrid2D_ObjCluster, dimBlock2D>>>(objData_Dev, objClassIdx_Dev, centerData_Dev, distOfObjAndCluster_Dev, objNumInCluster_Dev, i, myParameter);

		/* ����ÿ��������������ĵ�ŷʽ����������������ǩ */
		//KmeansCUDA_Update_ObjClusterIdx1<<<dimGrid1D_16, dimBlock1D_16>>>(objClassIdx_Dev, distOfObjAndCluster_Dev, myParameter);
		KmeansCUDA_Update_ObjClusterIdx<<<dimGrid2D_ObjNum_BLOCKSIZE_16, dimBlock2D>>>(objClassIdx_Dev, distOfObjAndCluster_Dev, myParameter);
	}

	
	// ��ʱ����
	cudaEventRecord(end_GPU, 0);
	cudaEventSynchronize(end_GPU);
	cudaEventElapsedTime(&elaspsedTime, start_GPU, end_GPU);

	std::cout << "Kmeans ������ʱ��Ϊ��" << elaspsedTime << "ms." << std::endl;

	/* ������豸�˿������ڴ� */
	cudaMemcpy(objClassIdx_Host, objClassIdx_Dev, myParameter.objNum * sizeof(int), cudaMemcpyDeviceToHost);
	cudaMemcpy(centerData_Host, centerData_Dev, myParameter.objNum * myParameter.objLength * sizeof(float), cudaMemcpyDeviceToHost);

	/* �ͷ��豸���ڴ� */
	cudaFree(objData_Dev);
	cudaFree(objClassIdx_Dev);
	cudaFree(centerData_Dev);
	cudaFree(distOfObjAndCluster_Dev);
	cudaFree(objNumInCluster_Dev);
}