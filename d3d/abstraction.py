import enum
import logging
from collections import namedtuple

import numpy as np
from scipy.spatial.transform import Rotation

_logger = logging.getLogger("d3d")

class ObjectTag:
    '''
    This class stands for label tags associate with object target
    '''
    def __init__(self, labels, mapping, scores=None):
        if not issubclass(mapping, enum.Enum):
            raise ValueError("The object class mapping should be an Enum")
        self.mapping = mapping

        # sanity check
        if scores is None:
            if isinstance(labels, (list, tuple)):
                raise ValueError("There cannot be multiple labels without scores")
            self.labels = [labels]
            self.scores = [1]
        else:
            if not isinstance(labels, (list, tuple)):
                self.labels = [labels]
                self.scores = [scores]
            else:
                self.labels = labels
                self.scores = scores

        # convert labels to enum object
        for i in range(len(self.labels)):
            if isinstance(self.labels[i], str):
                self.labels[i] = self.mapping[self.labels[i]]
            elif isinstance(self.labels[i], int):
                self.labels[i] = self.mapping(self.labels[i])
                
        # sort labels descending
        order = list(reversed(np.argsort(self.scores)))
        self.labels = [self.labels[i] for i in order]
        self.scores = [self.scores[i] for i in order]

    def __str__(self):
        return "<ObjectTag, top class: %s>" % self.labels[0].name

class ObjectTarget3D:
    '''
    This class stands for a target in cartesian coordinate. The body coordinate is FLU (front-left-up).
    '''
    def __init__(self, position, orientation, dimension, tag, id=None):
        '''
        :param position: Position of object center (x,y,z)
        :param orientation: Object heading (direction of x-axis attached on body)
            with regard to x-axis of the world at the object center.
        :param dimension: Length of the object in 3 dimensions (lx,ly,lz)
        :param tag: Classification information of the object
        :param id: ID of the object used for tracking (optional)
        '''

        assert len(position) == 3, "Invalid position shape"
        self.position = np.array(position)

        assert len(dimension) == 3, "Invalid dimension shape"
        self.dimension = np.array(dimension)

        if isinstance(orientation, Rotation):
            self.orientation = orientation
        elif len(orientation) == 4:
            self.orientation = Rotation.from_quat(orientation)
        else:
            raise ValueError("Invalid rotation format")

        if isinstance(tag, ObjectTag):
            self.tag = tag
        else:
            raise ValueError("Label should be of type ObjectTag")

        self.id = id

    @property
    def tag_name(self):
        return self.tag.labels[0].name

    @property
    def tag_score(self):
        return self.tag.scores[0]

    @property
    def yaw(self):
        '''
        Return the rotation angle around z-axis (ignoring rotations in other two directions)
        '''
        angles = self.orientation.as_euler("ZYX")
        if abs(angles[1]) + abs(angles[2]) > 0.1:
            _logger.warn("The roll (%.2f) and pitch(%.2f) angle in objects may be to large to ignore!",
                angles[2], angles[1])
        return angles[0]

class ObjectTarget3DArray(list):
    def __init__(self, iterable=[]):
        super().__init__(iterable)

    def to_numpy(self, box_type="ground"):
        '''
        :param box_type: Decide how to represent the box
        '''
        if len(self) == 0:
            return np.empty((0, 8))

        def to_ground(box):
            cls_value = box.tag.labels[0].value
            arr = np.concatenate([box.position, box.dimension, [box.yaw, cls_value]])
            return arr # store only 3D box and label
        return np.stack([to_ground(box) for box in self])

    def to_torch(self, box_type="ground"):
        import torch
        return torch.tensor(self.to_numpy(), box_type=box_type)

    def to_kitti(self):
        pass

    def __str__(self):
        return "<ObjectTarget3DArray with %d objects>" % len(self)

CameraMetadata = namedtuple('CameraMetadata', [
    'width', 'height',
    'distort_coeffs', # coefficients of camera distortion model, follow OpenCV format
    'distort_intri' # original intrinsic matrix used for cv2.undistortPoints
])
LidarMetadata = namedtuple('LidarMetadata', [])
class TransformSet:
    '''
    This object load a collection of intrinsic and extrinsic parameters
    All extrinsic parameters are stored as transform from base frame to its frame
    In this class, we require all frames to use FLU coordinate including camera frame
    '''
    def __init__(self, base_frame):
        '''
        :param base_frame: name of base frame used by extrinsics
        '''
        self.base_frame = base_frame
        self.intrinsics = {}
        self.intrinsics_meta = {}
        self.extrinsics = {} # transforms from base frame
        
    def _assert_exist(self, frame_id, extrinsic=False):
        if frame_id not in self.intrinsics:
            raise ValueError("Frame {0} not found in intrinsic parameters, "
                "please add intrinsics for {0} first!".format(frame_id))

        if extrinsic and frame_id not in self.extrinsics:
            raise ValueError("Frame {0} not found in extrinsic parameters, "
                "please add extrinsic for {0} first!".format(frame_id))

    def set_intrinsic_camera(self, frame_id, transform, size, rotate=True, distort_coeffs=[], distort_intri=None):
        '''
        Set camera intrinsics
        :param size: (width, height)
        :param rotate: if True, then transform will append an axis rotation (Front-Left-Up to Right-Down-Front)
        '''
        width, height = size
        if rotate:
            transform = transform.dot(np.array([
                [0,-1,0],
                [0,0,-1],
                [1,0,0]
            ]))

        self.intrinsics[frame_id] = transform
        self.intrinsics_meta[frame_id] = CameraMetadata(width, height, distort_coeffs, distort_intri)

    def set_intrinsic_lidar(self, frame_id):
        self.intrinsics[frame_id] = None
        self.intrinsics_meta[frame_id] = LidarMetadata()

    def set_intrinsic_pinhole(self, frame_id, size, cx, cy, fx, fy, s=0, distort_coeffs=[]):
        '''
        Set camera intrinsics with pinhole model parameters
        :param s: skew coefficient
        '''
        P = np.array([[fx, s, cx], [0, fy, cy], [0, 0, 1]])
        self.set_intrinsic_camera(frame_id, P, size,
            rotate=True, distort_coeffs=distort_coeffs, distort_intri=P)

    def set_extrinsic(self, transform, frame_to=None, frame_from=None):
        '''
        All extrinsics are stored as transform convert point from `frame_from` to `frame_to`
        :param frame_from: If set to None, then the source frame is base frame
        :param frame_to: If set to None, then the target frame is base frame
        '''
        if frame_to == frame_from: # including the case when frame_to=frame_from=None
            # the projection matrix need to be indentity
            assert np.allclose(np.diag(transform) == 1)
            assert np.sum(transform) == np.sum(np.diag(transform))

        if transform.shape == (3, 4):
            transform = np.vstack([transform, np.array([0]*3 + [1])])
        elif transform.shape != (4, 4):
            raise ValueError("Invalid matrix shape for extrinsics!")

        if frame_to is None:
            self._assert_exist(frame_from)
            self.extrinsics[frame_from] = np.linalg.inv(transform)
            return
        else:
            self._assert_exist(frame_to)

        if frame_from is None:
            self._assert_exist(frame_to)
            self.extrinsics[frame_to] = transform
            return
        else:
            self._assert_exist(frame_from)

        if frame_from in self.extrinsics:
            self.extrinsics[frame_to] = np.dot(transform, self.extrinsics[frame_from])
        elif frame_to in self.extrinsics:
            self.extrinsics[frame_from] = np.dot(transform, np.linalg.inv(self.extrinsics[frame_to]))
        else:
            raise ValueError("All frames are not present in extrinsics! "
                "Please add one of them first!")

    def get_extrinsic(self, frame_to=None, frame_from=None):
        '''
        :param frame_from: If set to None, then the source frame is base frame
        '''
        if frame_to == frame_from:
            return 1 # identity

        if frame_from is not None:
            self._assert_exist(frame_from, extrinsic=True)
            if frame_to is not None:
                self._assert_exist(frame_to, extrinsic=True)
                return np.dot(self.extrinsics[frame_to], np.linalg.inv(self.extrinsics[frame_from]))
            else:
                return np.linalg.inv(self.extrinsics[frame_from])
        else:
            if frame_to is not None:
                self._assert_exist(frame_to, extrinsic=True)
                return self.extrinsics[frame_to]
            else:
                raise ValueError("All frames are not present in extrinsics! "
                    "Please add extrinsics first!")

    @property
    def frames(self):
        return list(self.intrinsics.keys())

    def project_points_to_camera(self, points, frame_to, frame_from=None):
        width, height, distorts, distort_intri = self.intrinsics_meta[frame_to]
        tr = self.get_extrinsic(frame_to=frame_to, frame_from=frame_from)
        homo_xyz = np.insert(points[:, :3], 3, 1, axis=1)

        homo_uv = self.intrinsics[frame_to].dot(tr.dot(homo_xyz.T)[:3])
        d = homo_uv[2, :]
        u, v = homo_uv[0, :] / d, homo_uv[1, :] / d

        # mask points that are in camera view
        mask = (0 < u) & (u < width) & (0 < v) & (v < height) & (d > 0)
        mask, = np.where(mask)
        u, v = u[mask], v[mask]

        distorts = np.array(distorts)
        if distorts.size > 0:
            import cv2
            undistort = cv2.undistortPoints(np.array([u, v]).T,
                distort_intri, np.array(distorts), None, None, distort_intri)
            u, v = undistort[:, 0, 0], undistort[:, 0, 1]

            # mask again
            dmask = (0 < u) & (u < width) & (0 < v) & (v < height)
            u, v = u[dmask], v[dmask]
            mask = mask[dmask]

        return np.array([u, v]).T, mask
