import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:spotiflac_android/services/cover_cache_manager.dart';

class CachedCoverImage extends StatelessWidget {
  static const int _defaultMinCacheExtent = 64;
  static const int _defaultMaxCacheExtent = 512;

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final Widget Function(BuildContext, String, Object)? errorWidget;
  final Widget Function(BuildContext, String)? placeholder;
  final BorderRadius? borderRadius;
  final bool resizeDiskCache;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;

  const CachedCoverImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.memCacheWidth,
    this.memCacheHeight,
    this.errorWidget,
    this.placeholder,
    this.borderRadius,
    this.resizeDiskCache = false,
    this.fadeInDuration = Duration.zero,
    this.fadeOutDuration = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    final autoMemCacheWidth =
        memCacheWidth ?? _cacheExtentForLogicalSize(context, width);
    final autoMemCacheHeight =
        memCacheHeight ?? _cacheExtentForLogicalSize(context, height);
    final diskCacheWidth = resizeDiskCache ? autoMemCacheWidth : null;
    final diskCacheHeight = resizeDiskCache ? autoMemCacheHeight : null;
    final image = CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      memCacheWidth: autoMemCacheWidth,
      memCacheHeight: autoMemCacheHeight,
      maxWidthDiskCache: diskCacheWidth,
      maxHeightDiskCache: diskCacheHeight,
      cacheManager: CoverCacheManager.instance,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      useOldImageOnUrlChange: true,
      filterQuality: FilterQuality.low,
      errorWidget: errorWidget,
      placeholder: placeholder,
    );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: image);
    }

    return image;
  }

  static int? _cacheExtentForLogicalSize(BuildContext context, double? size) {
    if (size == null || !size.isFinite || size <= 0) return null;
    final dpr = MediaQuery.devicePixelRatioOf(
      context,
    ).clamp(1.0, 3.0).toDouble();
    return (size * dpr)
        .round()
        .clamp(_defaultMinCacheExtent, _defaultMaxCacheExtent)
        .toInt();
  }
}

CachedNetworkImageProvider cachedCoverImageProvider(String url) {
  return CachedNetworkImageProvider(
    url,
    cacheManager: CoverCacheManager.instance,
  );
}

int coverImageCacheExtent(
  BuildContext context,
  double logicalSize, {
  int min = 64,
  int max = 512,
}) {
  final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0).toDouble();
  return (logicalSize * dpr).round().clamp(min, max).toInt();
}
