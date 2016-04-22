import ctypes
import numpy as np
import pandas

from libc.stdint cimport uintptr_t
from libc.string cimport memcpy
from libc.stdio cimport printf
from libcpp cimport bool

cimport numpy as np

cdef extern from "device_types.h":
    ctypedef enum cudaMemcpyKind:
        cudaMemcpyHostToHost,
        cudaMemcpyHostToDevice,
        cudaMemcpyDeviceToHost,
        cudaMemcpyDeviceToDevice,
        cudaMemcpyDefault

cdef extern from "cuda_runtime_api.h" nogil:
    ctypedef int cudaError_t
    ctypedef int cudaMemoryType
    cdef struct cudaPointerAttributes:
        cudaMemoryType memoryType
        int device
        void *devicePointer
        void *hostPointer
        int isManaged
    cdef cudaError_t cudaPointerGetAttributes(cudaPointerAttributes *attributes, void *ptr) nogil
    cdef cudaError_t cudaMemcpy(void *dst, const void *src, size_t count, int kind)

cdef extern from "cudaImage.h" nogil:
    cdef cppclass CudaImage:
      int width
      int height
      int pitch
      float *h_data
      float *d_data
      float *t_data
      bool d_internalAlloc
      bool h_internalAlloc

      void Allocate(int width, int height, int pitch, bool withHost, float *devMem, float *hostMem)
      double Download()
      double Readback()
      double InitTexture()
      double CopyToTexture(CudaImage &dst, bool host)

    cdef int iDivUp(int a, int b)
    cdef int iDivDown(int a, int b)
    cdef int iAlignUp(int a, int b)
    cdef int iAlignDown(int a, int b)

cdef extern from "cudaSift.h" nogil:
    ctypedef struct SiftPoint:
        float xpos
        float ypos   
        float scale
        float sharpness
        float edgeness
        float orientation
        float score
        float ambiguity
        int match
        float match_xpos
        float match_ypos
        float match_error
        float subsampling
        float empty[3]
        float data[128]
    
    ctypedef struct SiftData:
        int numPts
        int maxPts
        SiftPoint *h_data
        SiftPoint *d_data
    cdef void InitCuda(int devNum)
    cdef void ExtractSift(
        SiftData &siftData, CudaImage &img, int numOctaves, 
        double initBlur, float thresh, float lowestScale, 
        float subsampling)
    cdef void InitSiftData(SiftData &data, int num, bool host, bool dev)
    cdef void FreeSiftData(SiftData &data)
    cdef void PrintSiftData(SiftData &data)
    cdef double MatchSiftData(SiftData &data1, SiftData &data2)
    cdef double FindHomography(
        SiftData &data,  float *homography, int *numMatches, 
        int numLoops, float minScore, float maxAmbiguity,
        float thresh)

def PyInitCuda(devNum=0):
    '''Initialize Cuda'''
    InitCuda(devNum)
    
PyInitCuda()

cdef class PySiftData:
    '''A wrapper around CudaSift's SiftData'''
    cdef:
        SiftData data
    def __init__(self, int num = 1024):
        with nogil:
            InitSiftData(self.data, num, False, True)
            
    def __deallocate__(self):
        with nogil:
            FreeSiftData(self.data)
    
    def __len__(self):
        return self.data.numPts
    
    def to_data_frame(self):
        '''Convert the device-side SIFT data to a Pandas data frame and array
        
        returns a Pandas data frame with the per-keypoint fields: xpos, ypos,
            scale, sharpness, edgeness, orientation, score and ambiguity
            AND a numpy N x 128 array of the SIFT features per keypoint
        '''
        cdef:
            SiftData *data = &self.data
            SiftPoint *pts
        nKeypoints = data.numPts;
        stride = sizeof(SiftPoint) / sizeof(float)
        dtype = np.dtype("f%d" % sizeof(float))
        h_data = np.zeros((nKeypoints, stride), dtype)
        pts = <SiftPoint *>h_data.data
        with nogil:
            cudaMemcpy(pts, data.d_data, sizeof(SiftPoint)*data.numPts, cudaMemcpyDeviceToHost)
        xpos_off = <size_t>(&pts.xpos - <float *>pts)
        ypos_off = <size_t>(&pts.ypos - <float *>pts)
        scale_off = <size_t>(&pts.scale - <float *>pts)
        sharpness_off = <size_t>(&pts.sharpness - <float *>pts)
        edgeness_off = <size_t>(&pts.edgeness - <float *>pts)
        orientation_off = <size_t>(&pts.orientation - <float *>pts)
        score_off = <size_t>(&pts.score - <float *>pts)
        ambiguity_off = <size_t>(&pts.ambiguity - <float *>pts)
        return pandas.concat((
            pandas.Series(h_data[:, xpos_off], name="xpos"),
            pandas.Series(h_data[:, ypos_off], name="ypos"),
            pandas.Series(h_data[:, scale_off], name="stride"),
            pandas.Series(h_data[:, sharpness_off], name="sharpness"),
            pandas.Series(h_data[:, edgeness_off], name="edgeness"),
            pandas.Series(h_data[:, orientation_off], name="orientation"),
            pandas.Series(h_data[:, score_off], name="score"),
            pandas.Series(h_data[:, ambiguity_off], name="ambiguity")
            ), axis=1), h_data[:, -128:]
    
    @staticmethod
    def from_data_frame(data_frame, features):
        '''Set a SiftData from a data frame and feature vector

        :param data_frame: a Pandas data frame with the per-keypoint fields:
            xpos, ypos, scale, sharpness, edgeness, orientation, score 
            and ambiguity
        :param features: a N x 128 array of SIFT features
        '''
        assert len(data_frame) == len(features)
        self = PySiftData(len(data_frame))
        cdef:
            SiftData *data = &self.data
            SiftPoint *pts
            size_t size = len(data_frame)
        
        tmp = np.zeros(
            (size, sizeof(SiftPoint) / sizeof(float)),
            dtype="f%d" % sizeof(float))
        pts = <SiftPoint *>tmp.data           
        xpos_off = <size_t>(&pts.xpos - <float *>pts)
        ypos_off = <size_t>(&pts.ypos - <float *>pts)
        scale_off = <size_t>(&pts.scale - <float *>pts)
        sharpness_off = <size_t>(&pts.sharpness - <float *>pts)
        edgeness_off = <size_t>(&pts.edgeness - <float *>pts)
        orientation_off = <size_t>(&pts.orientation - <float *>pts)
        score_off = <size_t>(&pts.score - <float *>pts)
        ambiguity_off = <size_t>(&pts.ambiguity - <float *>pts)
        tmp[:, xpos_off] = data_frame.xpos
        tmp[:, ypos_off] = data_frame.ypos
        tmp[:, scale_off] = data_frame.scale
        tmp[:, sharpness_off] = data_frame.sharpness
        tmp[:, edgeness_off] = data_frame.edgeness
        tmp[:, orientation_off] = data_frame.orientation
        tmp[:, score_off] = data_frame.score
        tmp[:, ambiguity_off] = data_frame.ambiguity
        tmp[:, -128:] = features
        data.numPts = size
        with nogil:
            cudaMemcpy(data.d_data, pts, sizeof(SiftPoint)*size, cudaMemcpyDeviceToHost)
        return self

def ExtractKeypoints(np.ndarray srcImage,
                     PySiftData pySiftData,
                     int numOctaves = 5, 
                     float initBlur = 0,
                     float thresh = 5,
                     float lowestScale = 0, 
                     float subsampling = 1.0):
    '''Extract keypoints from an image
    
    :param img: a Numpy 2d array (probably uint8)
    :param nKeypoints: maximum # of keypoints to fetch
    :param numOctaves: # of octaves to accumulate
    :param initBlur: the initial Gaussian standard deviation
    :param thresh: significance threshold for keypoints
    :param lowestScale:
    :param subsampling: subsampling in pixels
    
    returns a pandas data frame of SIFT points and an N x 128 numpy array of
        SIFT features per keypoint
    '''
    cdef:
        size_t i
        SiftPoint *pts
        CudaImage destImage
        size_t lim = srcImage.size
        size_t size_x = srcImage.shape[1]
        size_t size_y = srcImage.shape[0]
        np.ndarray tmp = np.ascontiguousarray(srcImage.astype(np.float32))
        void *pSrc = tmp.data
    with nogil:
        destImage.Allocate(size_x, size_y, iAlignUp(size_x, 128), 
                         False, NULL, NULL)
        cudaMemcpy(destImage.d_data, pSrc, sizeof(float) * size_x * size_y,
                   cudaMemcpyHostToDevice)
    del tmp
    with nogil:
        ExtractSift(pySiftData.data, destImage, numOctaves, initBlur, thresh,
                    lowestScale, subsampling)
