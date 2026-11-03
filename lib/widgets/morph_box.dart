import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// One surface that turns into another (owner 2026-11-02: "este mismo
/// sheet es el que se debe transformar" — the nav panel growing into the
/// whole trip): the face and the body both hang from its top edge at their
/// natural heights, and it is [t] of the way from the face's height to the
/// body's, clipping whatever is taller — so the face itself grows into the
/// body and folds back into it.
class MorphBox extends MultiChildRenderObjectWidget {
  const MorphBox({
    super.key,
    required this.t,
    this.fullWidth,
    this.inset = 0,
    this.onSizes,
    required super.children,
  });

  final double t;

  /// The body's width (null: as wide as the box), and the face's side
  /// margin inside it: the face is laid out at `fullWidth - 2 * inset` and
  /// the body at `fullWidth` the whole way, centred — so neither re-wraps
  /// while a floating panel's margins glide (the body squeezed into the
  /// floating width overflowed).
  final double? fullWidth;
  final double inset;

  /// Natural heights of the face and the body (null: no body), after the
  /// frame that changed them.
  final void Function(double face, double? body)? onSizes;

  @override
  RenderMorphBox createRenderObject(BuildContext context) =>
      RenderMorphBox(t, fullWidth, inset, onSizes);

  @override
  void updateRenderObject(BuildContext context, RenderMorphBox renderObject) {
    renderObject
      ..t = t
      ..fullWidth = fullWidth
      ..inset = inset
      ..onSizes = onSizes;
  }
}

class MorphBoxParentData extends ContainerBoxParentData<RenderBox> {}

class RenderMorphBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MorphBoxParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MorphBoxParentData> {
  RenderMorphBox(this._t, this._fullWidth, this._inset, this.onSizes);

  double _t;
  set t(double v) {
    if (v == _t) return;
    _t = v;
    markNeedsLayout();
  }

  double? _fullWidth;
  set fullWidth(double? v) {
    if (v == _fullWidth) return;
    _fullWidth = v;
    markNeedsLayout();
  }

  double _inset;
  set inset(double v) {
    if (v == _inset) return;
    _inset = v;
    markNeedsLayout();
  }

  void Function(double face, double? body)? onSizes;
  double? _lastFace;
  double? _lastBody;
  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MorphBoxParentData) {
      child.parentData = MorphBoxParentData();
    }
  }

  // Width fixed, height free: each part is as tall as what it carries (a
  // body taller than the screen caps itself and scrolls).
  double _bodyW(BoxConstraints c) => _fullWidth ?? c.maxWidth;
  double _faceW(BoxConstraints c) => math.max(0.0, _bodyW(c) - 2 * _inset);

  Size _blend(BoxConstraints c, double face, double? body) =>
      c.constrain(Size(c.maxWidth, face + ((body ?? face) - face) * _t));

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final face = firstChild;
    if (face == null) return constraints.smallest;
    final body = childAfter(face);
    return _blend(
        constraints,
        face
            .getDryLayout(BoxConstraints.tightFor(width: _faceW(constraints)))
            .height,
        body
            ?.getDryLayout(BoxConstraints.tightFor(width: _bodyW(constraints)))
            .height);
  }

  @override
  void performLayout() {
    final face = firstChild;
    if (face == null) {
      size = constraints.smallest;
      return;
    }
    final faceW = _faceW(constraints);
    final bodyW = _bodyW(constraints);
    face.layout(BoxConstraints.tightFor(width: faceW), parentUsesSize: true);
    final body = childAfter(face);
    body?.layout(BoxConstraints.tightFor(width: bodyW), parentUsesSize: true);
    final f = face.size.height;
    final b = body?.size.height;
    size = _blend(constraints, f, b);
    // Both centred on the panel; whatever is wider than it is clipped.
    (face.parentData! as MorphBoxParentData).offset =
        Offset((size.width - faceW) / 2, 0);
    if (body != null) {
      (body.parentData! as MorphBoxParentData).offset =
          Offset((size.width - bodyW) / 2, 0);
    }
    if (f != _lastFace || b != _lastBody) {
      _lastFace = f;
      _lastBody = b;
      // Never call out during layout — the listener may rebuild.
      final cb = onSizes;
      if (cb != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => cb(f, b));
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      defaultPaint,
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
