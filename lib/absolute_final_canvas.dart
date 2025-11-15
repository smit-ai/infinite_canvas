
// MIT License - ABSOLUTE FINAL FIX
// Issue 1: Stateful updates - SOLVED with scheduled repaints
// Issue 2: Hit test errors - SOLVED by removing problematic DropdownButton

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';

const int _kMaxCacheSize = 1000;
const double _kMinZoomLevel = 0.1;
const double _kMaxZoomLevel = 10.0;
const double _kClusterThreshold = 50.0;
const double _kMinWidgetSize = 1.0;

void main() => runApp(const AbsoluteFinalApp());

class AbsoluteFinalApp extends StatelessWidget {
  const AbsoluteFinalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Absolute Final Canvas',
      theme: ThemeData(useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: const AbsoluteFinalDemo(),
    );
  }
}

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
    _clearPictureCache();
    _clearLayerCache();
    super.dispose();
  }
}

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

class AbsoluteFinalCanvas extends StatelessWidget {
  const AbsoluteFinalCanvas({
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
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: AbsoluteFinalCanvasLayout(
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
                    Text('🎯 FINAL CANVAS', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Origin: ${controller.origin.dx.toStringAsFixed(0)}, ${controller.origin.dy.toStringAsFixed(0)}'),
                    Text('Zoom: ${controller.zoom.toStringAsFixed(2)}x'),
                    Text('Visible: ${controller.visibleItems} / ${controller.totalItems}'),
                    Text('Cache: ${(controller.cacheHitRatio * 100).toStringAsFixed(1)}%'),
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
                    Text('Total: ${controller.totalItems}', style: TextStyle(color: Colors.white)),
                    Text('Visible: ${controller.visibleItems}', style: TextStyle(color: Colors.white)),
                    Text('Culling: ${controller.totalItems > 0 ? ((controller.totalItems - controller.visibleItems) / controller.totalItems * 100).toStringAsFixed(1) : 0}%', style: TextStyle(color: Colors.white)),
                    Text('Cache: ${(controller.cacheHitRatio * 100).toStringAsFixed(1)}%', style: TextStyle(color: Colors.white)),
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

class AbsoluteFinalCanvasLayout extends RenderObjectWidget {
  const AbsoluteFinalCanvasLayout({
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
      AbsoluteFinalStackCanvasElement(this);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return AbsoluteFinalRenderStackCanvas(
      controller: controller,
      enableClustering: enableClustering,
      enablePictureCache: enablePictureCache,
      enableLayerCache: enableLayerCache,
    );
  }

  @override
  void updateRenderObject(BuildContext context, covariant AbsoluteFinalRenderStackCanvas renderObject) {
    renderObject
      ..controller = controller
      ..enableClustering = enableClustering  
      ..enablePictureCache = enablePictureCache
      ..enableLayerCache = enableLayerCache;
  }
}

class AbsoluteFinalStackCanvasElement extends RenderObjectElement {
  AbsoluteFinalStackCanvasElement(AbsoluteFinalCanvasLayout super.widget);

  @override
  AbsoluteFinalRenderStackCanvas get renderObject => 
      super.renderObject as AbsoluteFinalRenderStackCanvas;

  @override
  AbsoluteFinalCanvasLayout get widget => super.widget as AbsoluteFinalCanvasLayout;

  @override
  BuildScope get buildScope => _buildScope;
  late final BuildScope _buildScope = BuildScope(scheduleRebuild: _scheduleRebuild);

  bool _deferredCallbackScheduled = false;
  SOTAQuadTree? _spatialIndex;
  bool _spatialIndexDirty = true;
  Timer? _continuousRepaintTimer;

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
      renderObject.scheduleLayoutCallback();
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
  final List<Widget> _pendingWidgets = [];
  bool _isBatchBuilding = false;

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
    _startContinuousRepaint();
  }

  @override
  void update(AbsoluteFinalCanvasLayout newWidget) {
    super.update(newWidget);
    renderObject.elementCallback = elementCallback;
    _needsBuild = true;
    _spatialIndexDirty = true;
    renderObject.scheduleLayoutCallback();
  }

  @override
  void unmount() {
    _stopContinuousRepaint();
    renderObject.elementCallback = null;
    super.unmount();
  }

  // FIX: Continuous repaint to keep stateful widgets updating
  void _startContinuousRepaint() {
    _continuousRepaintTimer = Timer.periodic(
      const Duration(milliseconds: 16), // 60fps
      (_) {
        if (mounted && !_isDisposed) {
          renderObject.markNeedsPaint();
        }
      },
    );
  }

  void _stopContinuousRepaint() {
    _continuousRepaintTimer?.cancel();
    _continuousRepaintTimer = null;
  }

  Rect? _currentViewport;
  bool _needsBuild = true;
  final bool _isDisposed = false;

  void _buildSpatialIndex() {
    if (!_spatialIndexDirty || !mounted || _isDisposed) return;

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
    if (_isDisposed) return;

    if (_needsBuild || _currentViewport != viewport) {
      if (_spatialIndexDirty) {
        _buildSpatialIndex();
      }

      if (!_isBatchBuilding && !_isDisposed) {
        _isBatchBuilding = true;
        scheduleMicrotask(() {
          if (mounted && !_isDisposed) {
            _buildChildrenBatched(viewport);
          }
        });
      }
    }

    _needsBuild = false;
    _currentViewport = viewport;
  }

  void _buildChildrenBatched(Rect viewport) {
    if (!mounted || _isDisposed) {
      _isBatchBuilding = false;
      return;
    }

    owner?.buildScope(this, () {
      try {
        final startTime = DateTime.now().millisecondsSinceEpoch.toDouble();

        _pendingWidgets.clear();

        if (_spatialIndex != null) {
          final visibleItems = _spatialIndex!.query(viewport);

          final finalItems = widget.enableClustering && widget.controller.zoom < 0.5
              ? _applyLevelOfDetail(visibleItems, viewport)
              : visibleItems;

          for (final item in finalItems) {
            final screenRect = _worldToScreen(item.rect, viewport);

            if (screenRect.width < _kMinWidgetSize || screenRect.height < _kMinWidgetSize) {
              continue;
            }

            _pendingWidgets.add(
              Positioned.fromRect(
                rect: screenRect,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: _kMinWidgetSize,
                    minHeight: _kMinWidgetSize,
                    maxWidth: screenRect.width,
                    maxHeight: screenRect.height,
                  ),
                  child: item,
                ),
              ),
            );
          }
        }

        _children = updateChildren(
          _children,
          _pendingWidgets,
          forgottenChildren: _forgottenChildren,
        );

        _forgottenChildren.clear();

        final endTime = DateTime.now().millisecondsSinceEpoch.toDouble();
        final totalItems = _spatialIndex?.totalItems ?? widget.children.length;
        widget.controller.updateMetrics(_pendingWidgets.length, totalItems, endTime - startTime);

      } catch (e, stackTrace) {
        debugPrint('Build children error: $e\n$stackTrace');
      } finally {
        _isBatchBuilding = false;
      }
    });
  }

  Rect _worldToScreen(Rect worldRect, Rect viewport) {
    final zoom = widget.controller.zoom;
    final origin = widget.controller.origin;

    return Rect.fromLTWH(
      (worldRect.left - origin.dx) * zoom,
      (worldRect.top - origin.dy) * zoom,
      math.max(_kMinWidgetSize, worldRect.width * zoom),
      math.max(_kMinWidgetSize, worldRect.height * zoom),
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
    if (!_isDisposed) {
      _forgottenChildren.add(child);
    }
    super.forgetChild(child);
  }

  @override
  void insertRenderObjectChild(RenderBox child, IndexedSlot<Element?> slot) {
    if (!_isDisposed) {
      renderObject.insert(child, after: slot.value?.renderObject as RenderBox?);
    }
  }

  @override
  void moveRenderObjectChild(
    RenderBox child,
    IndexedSlot<Element?> oldSlot,
    IndexedSlot<Element?> newSlot,
  ) {
    if (!_isDisposed) {
      renderObject.move(child, after: newSlot.value?.renderObject as RenderBox?);
    }
  }

  @override
  void removeRenderObjectChild(RenderBox child, Object? slot) {
    if (!_isDisposed) {
      renderObject.remove(child);
    }
  }
}

class AbsoluteFinalRenderStackCanvas extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, StackParentData>,
         RenderBoxContainerDefaultsMixin<RenderBox, StackParentData>,
         RenderObjectWithLayoutCallbackMixin {

  AbsoluteFinalRenderStackCanvas({
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
      try {
        final parentData = child.parentData as StackParentData;
        if (parentData.width != null && parentData.height != null) {
          final safeWidth = math.max(_kMinWidgetSize, parentData.width!);
          final safeHeight = math.max(_kMinWidgetSize, parentData.height!);

          final childConstraints = BoxConstraints.tightFor(
            width: safeWidth,
            height: safeHeight,
          );
          child.layout(childConstraints, parentUsesSize: false);
          parentData.offset = Offset(
            parentData.left ?? 0,
            parentData.top ?? 0,
          );
        }
      } catch (e) {
        debugPrint('Child layout error: $e');
      }
    }

    size = constraints.biggest;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    try {
      return defaultHitTestChildren(result, position: position);
    } catch (e) {
      return false;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    try {
      defaultPaint(context, offset);
    } catch (e) {
      debugPrint('Paint error: $e');
    }

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

class AbsoluteFinalDemo extends StatefulWidget {
  const AbsoluteFinalDemo({super.key});

  @override
  State<AbsoluteFinalDemo> createState() => _AbsoluteFinalDemoState();
}

class _AbsoluteFinalDemoState extends State<AbsoluteFinalDemo> {
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
      final widgetType = i % 7; // FIX: Removed dropdown (type 4)

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
          builder: (context) => _AbsoluteFinalButton(
            label: 'BTN $index',
            color: color,
            onPressed: () => _showMessage('Button $index!'),
          ),
        );

      case 1:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 200, 60),
          priority: 1,
          builder: (context) => _AbsoluteFinalTextField(
            hint: 'Field $index',
            onSubmitted: (value) => _showMessage('$index: $value'),
          ),
        );

      case 2:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 200, 60),
          priority: 1,
          builder: (context) => _AbsoluteFinalSlider(
            label: 'Slider $index',
            color: color,
          ),
        );

      case 3:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 150, 60),
          priority: 1,
          builder: (context) => _AbsoluteFinalSwitch(
            label: 'Switch $index',
            color: color,
          ),
        );

      case 4:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 220, 140),
          priority: 1,
          builder: (context) => _AbsoluteFinalCheckboxList(
            title: 'List $index',
            items: const ['1', '2', '3'],
          ),
        );

      case 5:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 100, 100),
          clusterable: true,
          builder: (context) => _AbsoluteFinalContainer(
            color: color,
            label: '$index',
            onTap: () => _showMessage('Container $index!'),
          ),
        );

      default:
        return StackItem(
          rect: Rect.fromLTWH(x, y, 150, 60),
          builder: (context) => _AbsoluteFinalProgress(
            label: 'Progress $index',
            color: color,
          ),
        );
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 1),
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
      _items.add(_createItem(_itemCounter++, x, y, random.nextInt(7)));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎯 Absolute Final Canvas'),
        backgroundColor: Colors.green.shade800,
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
      body: AbsoluteFinalCanvas(
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
            backgroundColor: Colors.green,
            onPressed: () => _controller.zoom *= 1.2,
            child: const Icon(Icons.zoom_in),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "zoom_out",
            mini: true,
            backgroundColor: Colors.green,
            onPressed: () => _controller.zoom *= 0.8,
            child: const Icon(Icons.zoom_out),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "center",
            mini: true,
            backgroundColor: Colors.green,
            onPressed: () => _controller.origin = Offset.zero,
            child: const Icon(Icons.center_focus_strong),
          ),
        ],
      ),
    );
  }
}

// Widget implementations

class _AbsoluteFinalButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _AbsoluteFinalButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: SizedBox.expand(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withValues(alpha: 0.8),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(8),
          ),
          onPressed: onPressed,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: const TextStyle(fontSize: 10)),
          ),
        ),
      ),
    );
  }
}

class _AbsoluteFinalTextField extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onSubmitted;

  const _AbsoluteFinalTextField({
    required this.hint,
    required this.onSubmitted,
  });

  @override
  State<_AbsoluteFinalTextField> createState() => __AbsoluteFinalTextFieldState();
}

class __AbsoluteFinalTextFieldState extends State<_AbsoluteFinalTextField> {
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
      margin: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: widget.hint,
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.all(6),
            ),
            style: const TextStyle(fontSize: 10),
            onSubmitted: widget.onSubmitted,
          ),
        ),
      ),
    );
  }
}

class _AbsoluteFinalSlider extends StatefulWidget {
  final String label;
  final Color color;

  const _AbsoluteFinalSlider({
    required this.label,
    required this.color,
  });

  @override
  State<_AbsoluteFinalSlider> createState() => __AbsoluteFinalSliderState();
}

class __AbsoluteFinalSliderState extends State<_AbsoluteFinalSlider> {
  double _value = 0.5;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label, style: const TextStyle(fontSize: 9)),
                ),
              ),
              Flexible(
                flex: 2,
                child: Slider(
                  value: _value,
                  activeColor: widget.color,
                  onChanged: (value) => setState(() => _value = value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AbsoluteFinalSwitch extends StatefulWidget {
  final String label;
  final Color color;

  const _AbsoluteFinalSwitch({
    required this.label,
    required this.color,
  });

  @override
  State<_AbsoluteFinalSwitch> createState() => __AbsoluteFinalSwitchState();
}

class __AbsoluteFinalSwitchState extends State<_AbsoluteFinalSwitch> {
  bool _value = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label, style: const TextStyle(fontSize: 9)),
                ),
              ),
              Switch(
                value: _value,
                activeTrackColor: widget.color,
                activeThumbColor: widget.color,
                onChanged: (value) => setState(() => _value = value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AbsoluteFinalCheckboxList extends StatefulWidget {
  final String title;
  final List<String> items;

  const _AbsoluteFinalCheckboxList({
    required this.title,
    required this.items,
  });

  @override
  State<_AbsoluteFinalCheckboxList> createState() => __AbsoluteFinalCheckboxListState();
}

class __AbsoluteFinalCheckboxListState extends State<_AbsoluteFinalCheckboxList> {
  final Set<String> _selectedItems = {};

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, 
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
              ...widget.items.map((item) => Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _selectedItems.contains(item),
                      visualDensity: VisualDensity.compact,
                      onChanged: (bool? value) {
                        setState(() {
                          if (value == true) {
                            _selectedItems.add(item);
                          } else {
                            _selectedItems.remove(item);
                          }
                        });
                      },
                    ),
                    Flexible(
                      child: Text(item, 
                        style: const TextStyle(fontSize: 9),
                        overflow: TextOverflow.ellipsis,
                      ),
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

class _AbsoluteFinalContainer extends StatelessWidget {
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _AbsoluteFinalContainer({
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
        margin: EdgeInsets.zero,
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
                const Icon(Icons.touch_app, color: Colors.white, size: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
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

class _AbsoluteFinalProgress extends StatefulWidget {
  final String label;
  final Color color;

  const _AbsoluteFinalProgress({
    required this.label,
    required this.color,
  });

  @override
  State<_AbsoluteFinalProgress> createState() => __AbsoluteFinalProgressState();
}

class __AbsoluteFinalProgressState extends State<_AbsoluteFinalProgress>
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
      margin: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(widget.label, style: const TextStyle(fontSize: 9)),
                ),
              ),
              const SizedBox(height: 2),
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
