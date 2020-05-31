# cython: language_level=3, boundscheck=False, wraparound=False

import numpy as np
cimport numpy as np
import torch
from addict import Dict as edict

from libc.math cimport NAN, isnan, M_PI
from libcpp.vector cimport vector
from libcpp.unordered_map cimport unordered_map
from libcpp.unordered_set cimport unordered_set

from d3d.abstraction import ObjectTarget3DArray
from d3d.box import box2d_iou

cdef inline float weighted_mean(float a, int wa, float b, int wb):
    if wa == 0: return b
    elif wb == 0: return a
    else: return (a * wa + b * wb) / (wa + wb)

cdef int bisect(np.ndarray[ndim=1, dtype=float] arr, float x):
    '''Cython version of bisect.bisect_left'''
    cdef int lo=0, hi=arr.size, mid
    while lo < hi:
        mid = (lo+hi)//2
        if arr[mid] < x: lo = mid+1
        else: hi = mid
    return lo

cdef inline float calc_precision(int tp, int fp):
    if fp == 0: return 1
    else: return <float>tp / (tp + fp)
cdef inline float calc_recall(int tp, int fn):
    if fn == 0: return 1
    else: return <float>tp / (tp + fn)
cdef inline float calc_fscore(int tp, int fp, int fn, float b2):
    return (1+b2) * tp / ((1+b2)*tp + b2*fn + fp)

cdef class ObjectBenchmark:
    '''Benchmark for object detection'''
    # member declarations
    cdef int _pr_nsamples
    cdef float _min_score
    cdef unordered_set[int] _classes
    cdef object _class_type
    cdef unordered_map[int, float] _min_overlaps
    cdef np.ndarray _pr_thresholds

    # aggregated statistics declarations
    cdef unordered_map[int, int] _total_gt
    cdef unordered_map[int, vector[int]] _total_dt, _tp, _fp, _fn
    cdef unordered_map[int, vector[float]] _acc_angular, _acc_iou, _acc_box, _acc_dist

    def __init__(self, classes, min_overlaps, int pr_sample_count=40, float min_score=0, str pr_sample_scale="log10"):
        '''
        Object detection benchmark. Targets association is done by score sorting.

        :param classes: Object classes to consider
        :param min_overlaps: Min overlaps per class for two boxes being considered as overlap.
            If single value is provided, all class will use the same overlap threshold
        :param min_score: Min score for precision-recall samples
        :param pr_sample_count: Number of precision-recall sample points (expect for p=1,r=0 and p=0,r=1)
        :param pr_sample_scale: PR sample type, {lin: linspace, log: logspace 1~10, logX: logspace 1~X}

        TODO: add support for other threshold (e.g. center distance)
        '''
        # parse parameters
        if isinstance(classes, (list, tuple)):
            self._class_type = type(classes[0])
            for c in classes:
                self._classes.insert(c.value)
        else:
            self._class_type = type(classes)
            self._classes.insert(classes.value)
        if isinstance(min_overlaps, (list, tuple)):
            self._min_overlaps = {classes[i].value: v for i, v in enumerate(min_overlaps)}
        else:
            self._min_overlaps = {c: min_overlaps for c in self._classes}

        self._pr_nsamples = pr_sample_count
        self._min_score = min_score

        # generate score thresholds
        if pr_sample_scale == "lin":
            self._pr_thresholds = np.linspace(min_score, 1, pr_sample_count, endpoint=False, dtype=np.float32)
        elif pr_sample_scale.startswith("log"):
            logstart, logend = 1, int(pr_sample_scale[3:] or "10")
            self._pr_thresholds = np.geomspace(logstart, logend, pr_sample_count+1, dtype=np.float32)
            self._pr_thresholds = (self._pr_thresholds - logstart) * (1 - min_score) / (logend - logstart)
            self._pr_thresholds = (1 - self._pr_thresholds)[:1:-1]
        else:
            raise ValueError("Unrecognized PR sample type")

        # initialize maps
        for k in self._classes:
            self._total_gt[k] = 0
            self._total_dt[k] = vector[int](self._pr_nsamples, 0)
            self._tp[k] = vector[int](self._pr_nsamples, 0)
            self._fp[k] = vector[int](self._pr_nsamples, 0)
            self._fn[k] = vector[int](self._pr_nsamples, 0)

            self._acc_angular[k] = vector[float](self._pr_nsamples, NAN)
            self._acc_iou[k] = vector[float](self._pr_nsamples, NAN)
            self._acc_box[k] = vector[float](self._pr_nsamples, NAN)
            self._acc_dist[k] = vector[float](self._pr_nsamples, NAN)

    def reset(self):
        for k in self._classes:
            self._total_gt[k] = 0
            self._total_dt[k].assign(self._pr_nsamples, 0)
            self._tp[k].assign(self._pr_nsamples, 0)
            self._fp[k].assign(self._pr_nsamples, 0)
            self._fn[k].assign(self._pr_nsamples, 0)

            self._acc_angular[k].assign(self._pr_nsamples, NAN)
            self._acc_iou[k].assign(self._pr_nsamples, NAN)
            self._acc_box[k].assign(self._pr_nsamples, NAN)
            self._acc_dist[k].assign(self._pr_nsamples, NAN)

    cdef inline dict _aggregate_stats(self, vector[unordered_map[int, float]]& acc, vector[int]& gt_tags):
        '''Help put accuracy values into categories'''
        aggregated = {k: [[] for _ in range(self._pr_nsamples)] for k in self._classes}
        for score_idx in range(self._pr_nsamples):
            for iter in acc[score_idx]:
                aggregated[gt_tags[iter.first]][score_idx].append(iter.second)
        for k in self._classes:
            for score_idx in range(self._pr_nsamples):
                # assert len(aggregated[k][score_idx]) == tp[k][score_idx]
                if len(aggregated[k][score_idx]) > 0:
                    aggregated[k][score_idx] = sum(aggregated[k][score_idx]) / len(aggregated[k][score_idx])
                else:
                    aggregated[k][score_idx] = NAN
        return aggregated

    def get_stats(self, gt_boxes, dt_boxes): # TODO: add cython definition for abstraction classes
        assert type(gt_boxes) == ObjectTarget3DArray
        assert type(dt_boxes) == ObjectTarget3DArray
        assert gt_boxes.frame == dt_boxes.frame        

        # forward definitions
        cdef int thres_loc, dt_idx, dt_tagv

        # initialize statistics
        cdef unordered_map[int, int] ngt
        cdef unordered_map[int, vector[int]] tp, fp, fn, ndt
        cdef vector[unordered_map[int, int]] dt_assignment, gt_assignment
        cdef vector[unordered_map[int, float]] iou_acc, angular_acc, dist_acc, box_acc

        for k in self._classes:
            ngt[k] = 0
            ndt[k] = vector[int](self._pr_nsamples, 0)
            tp[k] = vector[int](self._pr_nsamples, 0)
            fp[k] = vector[int](self._pr_nsamples, 0)
            fn[k] = vector[int](self._pr_nsamples, 0)

            dt_assignment.resize(self._pr_nsamples)
            gt_assignment.resize(self._pr_nsamples)

            iou_acc.resize(self._pr_nsamples)
            angular_acc.resize(self._pr_nsamples)
            dist_acc.resize(self._pr_nsamples)
            box_acc.resize(self._pr_nsamples)

        # calculate iou and sort by score
        gt_array = gt_boxes.to_torch().float() # TODO: implement type dispatching
        dt_array = dt_boxes.to_torch().float()
        cdef np.ndarray[ndim=2, dtype=float] iou = box2d_iou(gt_array[:, [0,1,3,4,6]], dt_array[:, [0,1,3,4,6]], method="rbox").numpy() # TODO: method "box" has negative values...
        cdef np.ndarray[ndim=1, dtype=long] order = np.argsort([box.tag_score for box in dt_boxes])[::-1] # match from best score

        for gt_idx in range(len(gt_boxes)):
            # skip classes not required
            gt_tag = gt_boxes[gt_idx].tag_top
            if self._classes.find(gt_tag.value) == self._classes.end():
                continue
           
            for order_idx in range(len(order)):
                dt_idx = order[order_idx]
                # compare class information
                if dt_boxes[dt_idx].tag_top != gt_tag:
                    continue

                # true positive if overlap is larger than threshold
                if iou[gt_idx, dt_idx] > self._min_overlaps[gt_tag.value]:
                    thres_loc = bisect(self._pr_thresholds, dt_boxes[dt_idx].tag_score)
                    assert thres_loc >= 0, "Box score should be larger than min_score!"

                    # assign box
                    for score_idx in range(0, thres_loc):
                        # skip already assigned box
                        if dt_assignment[score_idx].find(dt_idx) != dt_assignment[score_idx].end():
                            continue

                        dt_assignment[score_idx][dt_idx] = gt_idx
                        gt_assignment[score_idx][gt_idx] = dt_idx

                        # caculate accuracy values for various criteria
                        iou_acc[score_idx][gt_idx] = iou[gt_idx, dt_idx]
                        dist_acc[score_idx][gt_idx] = np.linalg.norm(
                            gt_boxes[gt_idx].position - dt_boxes[dt_idx].position)
                        box_acc[score_idx][gt_idx] = np.linalg.norm(
                            gt_boxes[gt_idx].dimension - dt_boxes[dt_idx].dimension)

                        angular_acc_cur = (gt_boxes[gt_idx].orientation.inv() * dt_boxes[dt_idx].orientation).magnitude()
                        angular_acc[score_idx][gt_idx] = angular_acc_cur / M_PI
                    break

            ngt[gt_tag.value] += 1
            for score_idx in range(self._pr_nsamples):
                if gt_assignment[score_idx].find(gt_idx) != gt_assignment[score_idx].end():
                    tp[gt_tag.value][score_idx] += 1
                else:
                    fn[gt_tag.value][score_idx] += 1

        # compute false positives
        for dt_idx in range(len(dt_boxes)):
            dt_box = dt_boxes[dt_idx]
            dt_tagv = dt_box.tag_top.value
            if self._classes.find(dt_tagv) == self._classes.end():
                continue

            thres_loc = bisect(self._pr_thresholds, dt_boxes[dt_idx].tag_score)
            for score_idx in range(thres_loc):
                ndt[dt_tagv][score_idx] += 1
                if dt_assignment[score_idx].find(dt_idx) == dt_assignment[score_idx].end():
                    fp[dt_tagv][score_idx] += 1

        # compute accuracy metrics
        cdef vector[int] gt_tags
        gt_tags.reserve(len(gt_boxes))
        for box in gt_boxes:
            gt_tags.push_back(box.tag_top.value)

        return edict(ngt=ngt, ndt=ndt,
            tp=tp, fp=fp, fn=fn,
            acc_iou=self._aggregate_stats(iou_acc, gt_tags),
            acc_angular=self._aggregate_stats(angular_acc, gt_tags),
            acc_dist=self._aggregate_stats(dist_acc, gt_tags),
            acc_box=self._aggregate_stats(box_acc, gt_tags)
        )

    def add_stats(self, stats):
        '''
        Add statistics from get_stats into database
        '''
        for k in self._classes:
            self._total_gt[k] += stats.ngt[k]
            for i in range(self._pr_nsamples):
                # aggregate accuracies
                otp, ntp = self._tp[k][i], stats.tp[k][i]
                self._acc_angular[k][i] = weighted_mean(
                    self._acc_angular[k][i], otp, stats.acc_angular[k][i], ntp)
                self._acc_box[k][i] = weighted_mean(
                    self._acc_box[k][i], otp, stats.acc_box[k][i], ntp)
                self._acc_iou[k][i] = weighted_mean(
                    self._acc_iou[k][i], otp, stats.acc_iou[k][i], ntp)
                self._acc_dist[k][i] = weighted_mean(
                    self._acc_dist[k][i], otp, stats.acc_dist[k][i], ntp)

                # aggregate common stats
                self._total_dt[k][i] += stats.ndt[k][i]
                self._tp[k][i] += stats.tp[k][i]
                self._fp[k][i] += stats.fp[k][i]
                self._fn[k][i] += stats.fn[k][i]


    cdef inline int _get_score_idx(self, float score):
        if isnan(score):
            return self._pr_nsamples // 2
        else:
            return bisect(self._pr_thresholds, score)
    def gt_count(self):
        return self._total_gt
    def dt_count(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._total_dt}

    def tp(self, float score=NAN):
        '''Return true positive count. If score is not specified, return the median value'''
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._tp}
    def fp(self, float score=NAN):
        '''Return false positive count. If score is not specified, return the median value'''
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._fp}
    def fn(self, float score=NAN):
        '''Return false negative count. If score is not specified, return the median value'''
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._fn}

    def precision(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        if isnan(score):
            p = {k: [None] * self._pr_nsamples for k in self._classes}
            for k in self._classes:
                for i in range(self._pr_nsamples):
                    p[k][i] = calc_precision(self._tp[k][i], self._fp[k][i])
        else:
            p = {k: calc_precision(self._tp[k][score_idx], self._fp[k][score_idx]) for k in self._classes}
        return p
    def recall(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        if isnan(score):
            r = {k: [None] * self._pr_nsamples for k in self._classes}
            for k in self._classes:
                for i in range(self._pr_nsamples):
                    r[k][i] = calc_recall(self._tp[k][i], self._fn[k][i])
        else:
            r = {k: calc_recall(self._tp[k][score_idx], self._fn[k][score_idx]) for k in self._classes}
        return r
    def fscore(self, float score=NAN, float beta=1):
        cdef float b2 = beta * beta        
        cdef int score_idx = self._get_score_idx(score)
        if isnan(score):
            fs = {k: [None] * self._pr_nsamples for k in self._classes}
            for k in self._classes:
                for i in range(self._pr_nsamples):
                    fs[k][i] = calc_fscore(self._tp[k][i], self._fp[k][i], self._fn[k][i], b2)
        else:
            fs = {k: calc_fscore(self._tp[k][score_idx], self._fp[k][score_idx], self._fn[k][score_idx], b2)
                for k in self._classes}
        return fs

    def ap(self):
        '''Calculate (mean) average precision'''
        p, r = self.precision(), self.recall()
        # usually pr curve grows from bottom right to top left as score threshold
        # increases, so the area can be negative
        area = {k: -np.trapz(p[k], r[k]) for k in self._classes}
        return area

    def acc_iou(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._acc_iou}
    def acc_box(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._acc_box}
    def acc_dist(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._acc_dist}
    def acc_angular(self, float score=NAN):
        cdef int score_idx = self._get_score_idx(score)
        return {self._class_type(iter.first): iter.second[score_idx] for iter in self._acc_angular}

    def summary(self):
        '''
        Print default summary (into returned string)
        '''
        cdef float score_thres = 0.8
        cdef int score_idx = self._get_score_idx(score_thres)

        cdef list lines = [''] # prepend an empty line
        precision, recall = self.precision(score_thres), self.recall(score_thres)
        fscore, ap = self.fscore(), self.ap()

        lines.append("========== Benchmark Summary ==========")
        for k in self._classes:
            lines.append("Results for %s:" % self._class_type(k).name)
            lines.append("\tTotal processed targets:\t%d gt boxes, %d dt boxes" % (
                self._total_gt[k], max(self._total_dt[k])
            ))
            lines.append("\tPrecision (score > %.2f):\t%.3f" % (score_thres, precision[k]))
            lines.append("\tRecall (score > %.2f):\t\t%.3f" % (score_thres, recall[k]))
            lines.append("\tMax F1:\t\t\t\t%.3f" % max(fscore[k]))
            lines.append("\tAP:\t\t\t\t%.3f" % ap[k])
            lines.append("")
            lines.append("\tMean IoU (score > %.2f):\t\t%.3f" % (score_thres, self._acc_iou[k][score_idx]))
            lines.append("\tMean angular error (score > %.2f):\t%.3f" % (score_thres, self._acc_angular[k][score_idx]))
            lines.append("\tMean distance (score > %.2f):\t\t%.3f" % (score_thres, self._acc_dist[k][score_idx]))
            lines.append("\tMean box error (score > %.2f):\t\t%.3f" % (score_thres, self._acc_box[k][score_idx]))
        lines.append("========== Summary End ==========")

        return '\n'.join(lines)