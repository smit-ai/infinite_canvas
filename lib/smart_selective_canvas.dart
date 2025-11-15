
// MIT License - SMART Selective Repaint Canvas
// Fixes stateful widget updates WITHOUT continuous rebuilds
// Only repaints when necessary - CPU efficient

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';

// Performance Constants
const int _kMaxCacheSize = 1000;
const double _kMinZoomLevel = 0.1;
const double _kMaxZoomLevel = 10.0;
const double _kClusterThreshold = 50.0;
const int _kMaxBatchSize = 10;
const Duration _kBuildThrottle = Duration(milliseconds: 16);

void main() => runApp(const SmartCanvasApp());

class SmartCanvasApp extends StatelessWidget {
  const SmartCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Selective Canvas',
      theme: ThemeData(useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: const SmartDemo(),
    );
  }
}

/// SMART Stack Canvas Controller with selective repaint notifications
class StackCanvasController extends ChangeNotifier {
  StackCanvasController({
    Offset initialPosition = Offset.zero,
    double initialZoom = 1.0,
  })  : _origin = initialPosition,
        _zoom = initialZoom.clamp(_kMinZoomLevel, _kMaxZoomLevel);

  Offset _origin;
  double _zoom;

  final Map<String, ui.Picture> _pictureCache = <String, ui.Picture>{};
  final Queue<String> _cacheKeys = Queue<String>();
  final Map<String, LayerHandle<ContainerLayer>> _layerCache = {};

  int _visibleItems = 0;
  int _totalItems = 0;
  int _cacheHits = 0;
  int _cacheMisses = 0;
  double _lastFrameTime = 0;

  // SMART FIX: Callback for selective repaints (NOT continuous)
  VoidCallback? _onWidgetNeedsRepaint;

  Offset get origin => _origin;
  double get zoom => _zoom;
  int get visibleItems => _visibleItems;
  int get totalItems => _totalItems;
  double get cacheHitRatio => (_cacheHits + _cacheMisses) > 0 
      ? _cacheHits / (_cacheHits + _cacheMisses) : 0.0;
  double get fps => _lastFrameTime > 0 ? 1000 / _lastFrameTime : 0;

  set origin(Offset value) {
    if (_origin != value) {
      _origin = value;
      notifyListeners();
    }
  }

  set zoom(double value) {
    final newZoom = value.clamp(_kMinZoomLevel, _kMaxZoomLevel);
    if (_zoom != newZoom) {
      _zoom = newZoom;
      _clearPictureCache();
      notifyListeners();
    }
  }

  void updateMetrics(int visibleCount, int totalCount, double frameTime) {
    _visibleItems = visibleCount;
    _totalItems = totalCount;
    _lastFrameTime = frameTime;
  }

  /*// SMART FIX: Register callback for selective repaints
  void setRepaintCallback(VoidCallback callback) {
    _onWidgetNeedsRepaint = callback;
  }*/
  
  // In StackCanvasController class:
void setRepaintCallback(VoidCallback? callback) { // FIX: Make nullable
  _onWidgetNeedsRepaint = callback;
}

  // SMART FIX: Trigger repaint ONLY when stateful widgets actually change
  void requestRepaint() {
    _onWidgetNeedsRepaint?.call();
  }

  ui.Picture? getCachedPicture(String key) {
    if (_pictureCache.containsKey(key)) {
      _cacheHits++;
      final picture = _pictureCache.remove(key)!;
      _pictureCache[key] = picture;
      return picture;
    }
    _cacheMisses++;
    return null;
  }

  void cachePicture(String key, ui.Picture picture) {
    if (_pictureCache.length >= _kMaxCacheSize) {
      final oldestKey = _cacheKeys.removeFirst();
      _pictureCache.remove(oldestKey)?.dispose();
    }
    _pictureCache[key] = picture;
    _cacheKeys.add(key);
  }

  LayerHandle<ContainerLayer>? getCachedLayer(String key) {
    return _layerCache[key];
  }

  void cacheLayer(String key, LayerHandle<ContainerLayer> layer) {
    _layerCache[key] = layer;
  }

  void _clearPictureCache() {
    for (final picture in _pictureCache.values) {
      picture.dispose();
    }
    _pictureCache.clear();
    _cacheKeys.clear();
  }

  void _clearLayerCache() {
    _layerCache.clear();
  }

  @override
  void dispose() {
    _onWidgetNeedsRepaint = null;
    _clearPictureCache();
    _clearLayerCache();
    super.dispose();
  }
}

/// QuadTree spatial index
class SOTAQuadTree {
  static const int _maxDepth = 8;
  static const int _maxItemsPerNode = 16;

  final Rect bounds;
  final int depth;
  final List<StackItem> items = [];
  final List<SOTAQuadTree> children = [];
  bool _divided = false;

  SOTAQuadTree(this.bounds, [this.depth = 0]);

  bool insert(StackItem item) {
    if (!bounds.overlaps(item.rect)) return false;

    if (items.length < _maxItemsPerNode || depth >= _maxDepth) {
      items.add(item);
      return true;
    }

    if (!_divided) _subdivide();

    for (final child in children) {
      if (child.insert(item)) break;
    }
    return true;
  }

  void _subdivide() {
    final x = bounds.left;
    final y = bounds.top;
    final w = bounds.width / 2;
    final h = bounds.height / 2;

    children.addAll([
      SOTAQuadTree(Rect.fromLTWH(x, y, w, h), depth + 1),
      SOTAQuadTree(Rect.fromLTWH(x + w, y, w, h), depth + 1),
      SOTAQuadTree(Rect.fromLTWH(x, y + h, w, h), depth + 1),
      SOTAQuadTree(Rect.fromLTWH(x + w, y + h, w, h), depth + 1),
    ]);
    _divided = true;
  }

  List<StackItem> query(Rect range, [List<StackItem>? found]) {
    found ??= <StackItem>[];
    if (!bounds.overlaps(range)) return found;

    for (final item in items) {
      if (item.rect.overlaps(range)) found.add(item);
    }

    if (_divided) {
      for (final child in children) {
        child.query(range, found);
      }
    }

    return found;
  }

  int get totalItems {
    int count = items.length;
    if (_divided) {
      for (final child in children) {
        count += child.totalItems;
      }
    }
    return count;
  }
}

/// StackItem - Works with ANY Flutter widget
class StackItem extends StatelessWidget {
  const StackItem({
    super.key,
    required this.rect,
    required this.builder,
    this.cacheKey,
    this.clusterable = false,
    this.priority = 0,
  });

  final Rect rect;
  final WidgetBuilder builder;
  final String? cacheKey;
  final bool clusterable;
  final int priority;

  @override
  Widget build(BuildContext context) {
    return Builder(builder: builder);
  }

  String get effectiveCacheKey => 
      cacheKey ?? '${rect.hashCode}_${builder.hashCode}';
}

/// Smart Canvas Widget - NO continuous rebuilds
class SmartCanvas extends StatelessWidget {
  const SmartCanvas({
    super.key,
    required this.controller,
    required this.children,
    this.enableClustering = true,
    this.enablePictureCache = true,
    this.enableLayerCache = true,
    this.showDebugInfo = false,
    this.showPerformanceOverlay = false,
  });

  final StackCanvasController controller;
  final List<StackItem> children;
  final bool enableClustering;
  final bool enablePictureCache;
  final bool enableLayerCache;
  final bool showDebugInfo;
  final bool showPerformanceOverlay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const Center(child: CircularProgressIndicator());
        }

        return MouseRegion(
          onEnter: (_) {},
          onExit: (_) {},
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                final zoomDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                controller.zoom *= zoomDelta;
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (details) {},
              onScaleUpdate: (details) {
                if (details.scale == 1.0) {
                  controller.origin -= details.focalPointDelta / controller.zoom;
                } else {
                  final previousZoom = controller.zoom;
                  controller.zoom *= details.scale;

                  final viewportCenter = Offset(
                    constraints.maxWidth / 2,
                    constraints.maxHeight / 2,
                  );
                  final focalPoint = details.localFocalPoint;
                  final worldFocalBefore = controller.origin + (focalPoint - viewportCenter) / previousZoom;
                  final worldFocalAfter = controller.origin + (focalPoint - viewportCenter) / controller.zoom;
                  controller.origin += worldFocalBefore - worldFocalAfter;
                }
              },
              onScaleEnd: (details) {},
              child: RepaintBoundary(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned.fill(
                      child: SmartCanvasLayout(
                        controller: controller,
                        enableClustering: enableClustering,
                        enablePictureCache: enablePictureCache,
                        enableLayerCache: enableLayerCache,
                        children: children,
                      ),
                    ),
                    if (showDebugInfo) _buildDebugOverlay(),
                    if (showPerformanceOverlay) _buildPerformanceOverlay(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDebugOverlay() {
    return Positioned(
      top: 16,
      right: 16,
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('🎯 SMART CANVAS', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Origin: ${controller.origin.dx.toStringAsFixed(0)}, ${controller.origin.dy.toStringAsFixed(0)}'),
                    Text('Zoom: ${controller.zoom.toStringAsFixed(2)}x'),
                    Text('Visible: ${controller.visibleItems} / ${controller.totalItems}'),
                    Text('Cache Hit: ${(controller.cacheHitRatio * 100).toStringAsFixed(1)}%'),
                    Text('FPS: ${controller.fps.toStringAsFixed(1)}'),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPerformanceOverlay() {
    return Positioned(
      top: 16,
      left: 16,
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return Card(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('⚡ PERFORMANCE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    Text('Total Items: ${controller.totalItems}', style: TextStyle(color: Colors.white)),
                    Text('Visible Items: ${controller.visibleItems}', style: TextStyle(color: Colors.white)),
                    Text('Culling: ${controller.totalItems > 0 ? ((controller.totalItems - controller.visibleItems) / controller.totalItems * 100).toStringAsFixed(1) : 0}%', style: TextStyle(color: Colors.white)),
                    Text('Cache Hit: ${(controller.cacheHitRatio * 100).toStringAsFixed(1)}%', style: TextStyle(color: Colors.white)),
                    Text('FPS: ${controller.fps.toStringAsFixed(1)}', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            );
          },
        ),
      ),  
    );
  }
}

/// Canvas Layout Widget
class SmartCanvasLayout extends RenderObjectWidget {
  const SmartCanvasLayout({
    super.key,
    required this.controller,
    required this.children,
    this.enableClustering = true,
    this.enablePictureCache = true,
    this.enableLayerCache = true,
  });

  final StackCanvasController controller;
  final List<StackItem> children;
  final bool enableClustering;
  final bool enablePictureCache;
  final bool enableLayerCache;

  @override
  RenderObjectElement createElement() => 
      SmartStackCanvasElement(this);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return SmartRenderStackCanvas(
      controller: controller,
      enableClustering: enableClustering,
      enablePictureCache: enablePictureCache,
      enableLayerCache: enableLayerCache,
    );
  }

  @override
  void updateRenderObject(BuildContext context, covariant SmartRenderStackCanvas renderObject) {
    renderObject
      ..controller = controller
      ..enableClustering = enableClustering  
      ..enablePictureCache = enablePictureCache
      ..enableLayerCache = enableLayerCache;
  }
}

/// Smart Stack Canvas Element with selective repaints
class SmartStackCanvasElement extends RenderObjectElement {
  SmartStackCanvasElement(SmartCanvasLayout super.widget);

  @override
  SmartRenderStackCanvas get renderObject => 
      super.renderObject as SmartRenderStackCanvas;

  @override
  SmartCanvasLayout get widget => super.widget as SmartCanvasLayout;

  @override
  BuildScope get buildScope => _buildScope;
  late final BuildScope _buildScope = BuildScope(scheduleRebuild: _scheduleRebuild);

  bool _deferredCallbackScheduled = false;
  SOTAQuadTree? _spatialIndex;
  bool _spatialIndexDirty = true;

  Timer? _rebuildTimer;
  bool _rebuildPending = false;

  void _scheduleRebuild() {
    if (_deferredCallbackScheduled) return;

    final bool deferMarkNeedsLayout = switch (SchedulerBinding.instance.schedulerPhase) {
      SchedulerPhase.idle ||
      SchedulerPhase.postFrameCallbacks => true,
      SchedulerPhase.transientCallbacks ||
      SchedulerPhase.midFrameMicrotasks ||
      SchedulerPhase.persistentCallbacks => false,
    };

    if (!deferMarkNeedsLayout) {
      if (!_rebuildPending) {
        _rebuildPending = true;
        _rebuildTimer?.cancel();
        _rebuildTimer = Timer(_kBuildThrottle, () {
          _rebuildPending = false;
          if (mounted) {
            renderObject.scheduleLayoutCallback();
          }
        });
      }
      return;
    }

    _deferredCallbackScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_frameCallback);
  }

  void _frameCallback(Duration timestamp) {
    _deferredCallbackScheduled = false;
    if (mounted) {
      renderObject.scheduleLayoutCallback();
    }
  }

  var _children = <Element>[]; 
  final Set<Element> _forgottenChildren = <Element>{};

  @override
  void visitChildren(ElementVisitor visitor) {
    for (final Element child in _children) {
      if (!_forgottenChildren.contains(child)) {
        visitor(child);
      }
    }
  }

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    renderObject.elementCallback = elementCallback;
    _buildSpatialIndex();

    // SMART FIX: Register selective repaint callback
    widget.controller.setRepaintCallback(_onRepaintRequested);
  }

  @override
  void update(SmartCanvasLayout newWidget) {
    super.update(newWidget);
    renderObject.elementCallback = elementCallback;
    _needsBuild = true;
    _spatialIndexDirty = true;
    renderObject.scheduleLayoutCallback();

    // SMART FIX: Update repaint callback if controller changed
    widget.controller.setRepaintCallback(_onRepaintRequested);
  }

  /*@override
  void unmount() {
    _rebuildTimer?.cancel();
    widget.controller.setRepaintCallback(null as VoidCallback);
    renderObject.elementCallback = null;
    super.unmount();
  }*/
  
  // In Element unmount:
@override
void unmount() {
  _rebuildTimer?.cancel();
  widget.controller.setRepaintCallback(null); // FIX: Now works
  renderObject.elementCallback = null;
  super.unmount();
}

  // SMART FIX: Called ONLY when stateful widgets actually change
  void _onRepaintRequested() {
    if (mounted) {
      renderObject.markNeedsPaint();
    }
  }

  Rect? _currentViewport;
  bool _needsBuild = true;

  void _buildSpatialIndex() {
    if (!_spatialIndexDirty || !mounted) return;

    try {
      Rect? bounds;
      for (final item in widget.children) {
        bounds = bounds?.expandToInclude(item.rect) ?? item.rect;
      }

      if (bounds != null && widget.children.isNotEmpty) {
        bounds = bounds.inflate(100);
        _spatialIndex = SOTAQuadTree(bounds);

        for (final item in widget.children) {
          _spatialIndex!.insert(item);
        }
      }

      _spatialIndexDirty = false;
    } catch (e) {
      debugPrint('Spatial index build error: $e');
      _spatialIndexDirty = true;
    }
  }

  void elementCallback(Rect viewport) {
    if (_needsBuild || _currentViewport != viewport) {
      if (_spatialIndexDirty) {
        _buildSpatialIndex();
      }

      owner?.buildScope(this, () {
        try {
          final startTime = DateTime.now().millisecondsSinceEpoch.toDouble();

          final newChildren = <Widget>[];
          final visibleItems = <StackItem>[];

          if (_spatialIndex != null) {
            visibleItems.addAll(_spatialIndex!.query(viewport));

            if (widget.enableClustering && widget.controller.zoom < 0.5) {
              visibleItems.clear();
              visibleItems.addAll(_applyLevelOfDetail(_spatialIndex!.query(viewport), viewport));
            }
          } else {
            for (final child in widget.children) {
              if (child.rect.overlaps(viewport)) {
                visibleItems.add(child);
              }
            }
          }

          _processBatchedWidgets(visibleItems, viewport, newChildren);

          _children = updateChildren(
            _children,
            newChildren,
            forgottenChildren: _forgottenChildren,
          );

          _forgottenChildren.clear();

          final endTime = DateTime.now().millisecondsSinceEpoch.toDouble();
          final totalItems = _spatialIndex?.totalItems ?? widget.children.length;
          widget.controller.updateMetrics(newChildren.length, totalItems, endTime - startTime);

        } catch (e) {
          debugPrint('Element callback error: $e');
        }
      });
    }

    _needsBuild = false;
    _currentViewport = viewport;
  }

  void _processBatchedWidgets(List<StackItem> items, Rect viewport, List<Widget> output) {
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final screenRect = _worldToScreen(item.rect, viewport);

      // SMART FIX: Wrap in SmartRepaintWidget to notify controller on changes
      output.add(
        Positioned.fromRect(
          rect: screenRect,
          child: RepaintBoundary(
            child: SmartRepaintWidget(
              controller: widget.controller,
              child: item,
            ),
          ),
        ),
      );

      if (i > 0 && i % _kMaxBatchSize == 0) {
        break;
      }
    }
  }

  Rect _worldToScreen(Rect worldRect, Rect viewport) {
    final zoom = widget.controller.zoom;
    final origin = widget.controller.origin;

    return Rect.fromLTWH(
      (worldRect.left - origin.dx) * zoom,
      (worldRect.top - origin.dy) * zoom,
      worldRect.width * zoom,
      worldRect.height * zoom,
    );
  }

  List<StackItem> _applyLevelOfDetail(List<StackItem> items, Rect viewport) {
    if (items.length < 100) return items;

    final visibleItems = <StackItem>[];
    final clusterable = items.where((item) => item.clusterable).toList();
    final nonClusterable = items.where((item) => !item.clusterable).toList();

    final processed = List.filled(clusterable.length, false);

    for (int i = 0; i < clusterable.length; i++) {
      if (processed[i]) continue;

      final cluster = <StackItem>[clusterable[i]];
      processed[i] = true;

      for (int j = i + 1; j < clusterable.length; j++) {
        if (processed[j]) continue;

        final distance = (clusterable[i].rect.center - clusterable[j].rect.center).distance;
        if (distance < _kClusterThreshold / widget.controller.zoom) {
          cluster.add(clusterable[j]);
          processed[j] = true;
        }
      }

      final clusterThreshold = widget.controller.zoom < 0.3 ? 5 : 3;
      if (cluster.length > clusterThreshold) {
        visibleItems.add(cluster.first);
      } else {
        visibleItems.addAll(cluster);
      }
    }

    visibleItems.addAll(nonClusterable);
    return visibleItems;
  }

  @override
  void forgetChild(Element child) {
    _forgottenChildren.add(child);
    super.forgetChild(child);
  }

  @override
  void insertRenderObjectChild(RenderBox child, IndexedSlot<Element?> slot) {
    renderObject.insert(child, after: slot.value?.renderObject as RenderBox?);
  }

  @override
  void moveRenderObjectChild(
    RenderBox child,
    IndexedSlot<Element?> oldSlot,
    IndexedSlot<Element?> newSlot,
  ) {
    renderObject.move(child, after: newSlot.value?.renderObject as RenderBox?);
  }

  @override
  void removeRenderObjectChild(RenderBox child, Object? slot) {
    renderObject.remove(child);
  }
}

/// SMART FIX: Widget that notifies controller when children need repaint
class SmartRepaintWidget extends StatefulWidget {
  final StackCanvasController controller;
  final Widget child;

  const SmartRepaintWidget({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<SmartRepaintWidget> createState() => _SmartRepaintWidgetState();
}

class _SmartRepaintWidgetState extends State<SmartRepaintWidget> {
  @override
  void didUpdateWidget(SmartRepaintWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // SMART FIX: Request repaint ONLY when widget updates
    if (oldWidget.child != widget.child) {
      widget.controller.requestRepaint();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// RenderObject for canvas
class SmartRenderStackCanvas extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, StackParentData>,
         RenderBoxContainerDefaultsMixin<RenderBox, StackParentData>,
         RenderObjectWithLayoutCallbackMixin {

  SmartRenderStackCanvas({
    required StackCanvasController controller,
    bool enableClustering = true,
    bool enablePictureCache = true,
    bool enableLayerCache = true,
  }) : _controller = controller,
       _enableClustering = enableClustering,
       _enablePictureCache = enablePictureCache,
       _enableLayerCache = enableLayerCache;

  StackCanvasController _controller;
  bool _enableClustering;
  bool _enablePictureCache;  
  bool _enableLayerCache;
  void Function(Rect viewport)? _elementCallback;

  StackCanvasController get controller => _controller;
  bool get enableClustering => _enableClustering;
  bool get enablePictureCache => _enablePictureCache;
  bool get enableLayerCache => _enableLayerCache;

  set controller(StackCanvasController value) {
    if (_controller != value) {
      if (attached) {
        _controller.removeListener(_onOriginChanged);
        value.addListener(_onOriginChanged);
      }
      _controller = value;
    }
  }

  set enableClustering(bool value) {
    if (_enableClustering != value) {
      _enableClustering = value;
      markNeedsPaint();
    }
  }

  set enablePictureCache(bool value) {
    if (_enablePictureCache != value) {
      _enablePictureCache = value;
      markNeedsPaint();
    }
  }

  set enableLayerCache(bool value) {
    if (_enableLayerCache != value) {
      _enableLayerCache = value;
      markNeedsPaint();
    }
  }

  set elementCallback(void Function(Rect viewport)? value) {
    if (_elementCallback != value) {
      _elementCallback = value;
      if (_elementCallback != null) {
        scheduleLayoutCallback();
      }
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller.addListener(_onOriginChanged);
  }

  @override
  void detach() {
    _controller.removeListener(_onOriginChanged);
    super.detach();
  }

  void _onOriginChanged() {
    scheduleLayoutCallback();
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! StackParentData) {
      child.parentData = StackParentData();
    }
  }

  @override
  void layoutCallback() {
    final viewportSize = Size(
      constraints.maxWidth / _controller.zoom,
      constraints.maxHeight / _controller.zoom,
    );

    final viewport = Rect.fromLTWH(
      _controller.origin.dx,
      _controller.origin.dy,
      viewportSize.width,
      viewportSize.height,
    );

    if (_elementCallback != null) {
      _elementCallback!(viewport);
    }
  }

  @override
  void performLayout() {
    runLayoutCallback();

    final children = getChildrenAsList();
    for (final child in children) {
      final parentData = child.parentData as StackParentData;
      if (parentData.width != null && parentData.height != null) {
        final childConstraints = BoxConstraints.tightFor(
          width: parentData.width!,
          height: parentData.height!,
        );
        child.layout(childConstraints);
        parentData.offset = Offset(parentData.left!, parentData.top!);
      }
    }

    size = constraints.biggest;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);

    if (kDebugMode && debugPaintSizeEnabled) {
      context.canvas.drawRect(
        offset & size,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0xFF00FF00),
      );
    }
  }
}

/// Demo implementation with SMART stateful widgets
class SmartDemo extends StatefulWidget {
  const SmartDemo({super.key});

  @override
  State<SmartDemo> createState() => _SmartDemoState();
}

class _SmartDemoState extends State<SmartDemo> {
  late StackCanvasController _controller;
  List<StackItem> _items = [];
  bool _showDebugInfo = true;
  bool _showPerformanceOverlay = true;
  int _itemCounter = 0;

  @override
  void initState() {
    super.initState();
    _controller = StackCanvasController();
    _generateItems();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _generateItems() {
    final random = math.Random(42);
    _items = [];

    for (int i = 0; i < 50; i++) {
      final x = random.nextDouble() * 2000 - 1000;
      final y = random.nextDouble() * 2000 - 1000;
      final widgetType = i % 8;

      _items.add(_createItem(i, x, y, widgetType));
    }
  }

  StackItem _createItem(int index, double x, double y, int type) {
    const colors = [Colors.red, Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.teal, Colors.pink, Colors.cyan];
    final color = colors[index % colors.length];

    switch (type) {
      case 0:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 120, 50),
          priority: 1,
          builder: (context) => _SmartButton(
            label: 'Button $index',
            color: color,
            onPressed: () => _showMessage('Button $index pressed!'),
          ),
        );

      case 1:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 200, 60),
          priority: 1,
          builder: (context) => _SmartTextField(
            hint: 'Field $index',
            onSubmitted: (value) => _showMessage('Field $index: $value'),
          ),
        );

      case 2:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 200, 60),
          priority: 1,
          builder: (context) => _SmartSlider(
            label: 'Slider $index',
            color: color,
            controller: _controller,
          ),
        );

      case 3:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 150, 60),
          priority: 1,
          builder: (context) => _SmartSwitch(
            label: 'Switch $index',
            color: color,
            controller: _controller,
          ),
        );

      case 4:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 180, 60),
          priority: 1,
          builder: (context) => _SmartDropdown(
            label: 'Dropdown $index',
            items: const ['Option A', 'Option B', 'Option C'],
            controller: _controller,
          ),
        );

      case 5:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 200, 150),
          priority: 1,
          builder: (context) => _SmartCheckboxGroup(
            title: 'List $index',
            items: const ['Item 1', 'Item 2', 'Item 3'],
            controller: _controller,
          ),
        );

      case 6:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 100, 100),
          clusterable: true,
          builder: (context) => _SmartContainer(
            color: color,
            label: '$index',
            onTap: () => _showMessage('Container $index tapped!'),
          ),
        );

      default:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 150, 60),
          builder: (context) => _SmartProgress(
            label: 'Progress $index',
            color: color,
            controller: _controller,
          ),
        );
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _addNewItem() {
    if (!mounted) return;

    final random = math.Random();
    final x = random.nextDouble() * 1000 - 500 + _controller.origin.dx;
    final y = random.nextDouble() * 1000 - 500 + _controller.origin.dy;

    setState(() {
      _items.add(_createItem(_itemCounter++, x, y, random.nextInt(8)));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎯 Smart Canvas - Selective Repaint'),
        backgroundColor: Colors.purple.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addNewItem,
          ),
          IconButton(
            icon: Icon(_showDebugInfo ? Icons.bug_report : Icons.bug_report_outlined),
            onPressed: () => setState(() => _showDebugInfo = !_showDebugInfo),
          ),
          IconButton(
            icon: Icon(_showPerformanceOverlay ? Icons.speed : Icons.speed_outlined),
            onPressed: () => setState(() => _showPerformanceOverlay = !_showPerformanceOverlay),
          ),
        ],
      ),
      body: SmartCanvas(
        controller: _controller,
        enableClustering: true,
        enablePictureCache: true,
        enableLayerCache: true,
        showDebugInfo: _showDebugInfo,
        showPerformanceOverlay: _showPerformanceOverlay,
        children: _items,
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: "zoom_in",
            mini: true,
            backgroundColor: Colors.purple,
            onPressed: () => _controller.zoom *= 1.2,
            child: const Icon(Icons.zoom_in),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "zoom_out",
            mini: true,
            backgroundColor: Colors.purple,
            onPressed: () => _controller.zoom *= 0.8,
            child: const Icon(Icons.zoom_out),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "center",
            mini: true,
            backgroundColor: Colors.purple,
            onPressed: () => _controller.origin = Offset.zero,
            child: const Icon(Icons.center_focus_strong),
          ),
        ],
      ),
    );
  }
}

// SMART Widget implementations that notify controller on state changes

class _SmartButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _SmartButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.8),
            foregroundColor: Colors.white,
          ),
          onPressed: onPressed,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
        ),
      ),
    );
  }
}

class _SmartTextField extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onSubmitted;

  const _SmartTextField({
    required this.hint,
    required this.onSubmitted,
  });

  @override
  State<_SmartTextField> createState() => __SmartTextFieldState();
}

class __SmartTextFieldState extends State<_SmartTextField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: widget.hint,
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.all(8),
            ),
            style: const TextStyle(fontSize: 12),
            onSubmitted: widget.onSubmitted,
          ),
        ),
      ),
    );
  }
}

// SMART FIX: Slider notifies controller on change
class _SmartSlider extends StatefulWidget {
  final String label;
  final Color color;
  final StackCanvasController controller;

  const _SmartSlider({
    required this.label,
    required this.color,
    required this.controller,
  });

  @override
  State<_SmartSlider> createState() => __SmartSliderState();
}

class __SmartSliderState extends State<_SmartSlider> {
  double _value = 0.5;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label, style: const TextStyle(fontSize: 10)),
                ),
              ),
              Flexible(
                flex: 2,
                child: Slider(
                  value: _value,
                  activeColor: widget.color,
                  onChanged: (value) {
                    setState(() => _value = value);
                    // SMART FIX: Request repaint when slider changes
                    widget.controller.requestRepaint();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// SMART FIX: Switch notifies controller on change
class _SmartSwitch extends StatefulWidget {
  final String label;
  final Color color;
  final StackCanvasController controller;

  const _SmartSwitch({
    required this.label,
    required this.color,
    required this.controller,
  });

  @override
  State<_SmartSwitch> createState() => __SmartSwitchState();
}

class __SmartSwitchState extends State<_SmartSwitch> {
  bool _value = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label, style: const TextStyle(fontSize: 10)),
                ),
              ),
              Switch(
                value: _value,
                activeTrackColor: widget.color.withValues(alpha: 0.5),
                activeThumbColor: widget.color,
                onChanged: (value) {
                  setState(() => _value = value);
                  // SMART FIX: Request repaint when switch changes
                  widget.controller.requestRepaint();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// SMART FIX: Dropdown notifies controller on change
class _SmartDropdown extends StatefulWidget {
  final String label;
  final List<String> items;
  final StackCanvasController controller;

  const _SmartDropdown({
    required this.label,
    required this.items,
    required this.controller,
  });

  @override
  State<_SmartDropdown> createState() => __SmartDropdownState();
}

class __SmartDropdownState extends State<_SmartDropdown> {
  String? _selectedValue;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: DropdownButton<String>(
            hint: Text(widget.label, style: const TextStyle(fontSize: 12)),
            value: _selectedValue,
            isDense: true,
            isExpanded: true,
            items: widget.items.map((String value) {
              return DropdownMenuItem<String>(
                value: value,
                child: Text(value, style: const TextStyle(fontSize: 10)),
              );
            }).toList(),
            onChanged: (value) {
              setState(() => _selectedValue = value);
              // SMART FIX: Request repaint when selection changes
              widget.controller.requestRepaint();
            },
          ),
        ),
      ),
    );
  }
}

// SMART FIX: Checkbox group notifies controller on change
class _SmartCheckboxGroup extends StatefulWidget {
  final String title;
  final List<String> items;
  final StackCanvasController controller;

  const _SmartCheckboxGroup({
    required this.title,
    required this.items,
    required this.controller,
  });

  @override
  State<_SmartCheckboxGroup> createState() => __SmartCheckboxGroupState();
}

class __SmartCheckboxGroupState extends State<_SmartCheckboxGroup> {
  final Set<String> _selectedItems = {};

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ...widget.items.map((item) => Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _selectedItems.contains(item),
                      onChanged: (bool? value) {
                        setState(() {
                          if (value == true) {
                            _selectedItems.add(item);
                          } else {
                            _selectedItems.remove(item);
                          }
                        });
                        // SMART FIX: Request repaint when checkbox changes
                        widget.controller.requestRepaint();
                      },
                    ),
                    Flexible(
                      child: Text(item, style: const TextStyle(fontSize: 10)),
                    ),
                  ],
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmartContainer extends StatelessWidget {
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _SmartContainer({
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        elevation: 4,
        child: Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.touch_app, color: Colors.white, size: 20),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// SMART FIX: Progress indicator notifies controller on animation frames
class _SmartProgress extends StatefulWidget {
  final String label;
  final Color color;
  final StackCanvasController controller;

  const _SmartProgress({
    required this.label,
    required this.color,
    required this.controller,
  });

  @override
  State<_SmartProgress> createState() => __SmartProgressState();
}

class __SmartProgressState extends State<_SmartProgress>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(_controller);

    // SMART FIX: Request repaint on animation update
    _animation.addListener(() {
      widget.controller.requestRepaint();
    });

    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label, style: const TextStyle(fontSize: 10)),
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) {
                    return LinearProgressIndicator(
                      value: _animation.value,
                      backgroundColor: Colors.grey[300],
                      valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
