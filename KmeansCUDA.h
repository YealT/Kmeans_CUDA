#ifndef KMEANSCUDA_H
#define KMEANSCUDA_H

#include "ClassParameter.h"

/**
* ���ܣ����� Kmeans ����
* ���룺objData ��������
* �����objClusterIdx ÿ���������������
* �����clusterData ��������
* ���룺myPatameter �������
*/
void KmeansCUDA(float *objData, int *objClusterIdx, float*clusterData, sParameter myParameter);

#endif // KMEANSCUDA_H