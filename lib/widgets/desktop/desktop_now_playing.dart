import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/lyrics_translation_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/windows_audio_device_service.dart'
    show WindowsAudioStatus, windowsAudioStatus;
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/theme/player_artwork_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_window.dart';
import 'package:mornye/widgets/desktop/windows_audio_quick_settings.dart';
import 'package:mornye/widgets/lyrics_options_button.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/mornye_player_favorite_button.dart';
import 'package:mornye/widgets/mornye_player_queue.dart';
import 'package:mornye/widgets/no_scrollbars.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_metadata_title.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_volume_control.dart';

/// The two listening presentation modes in fullscreen / expanded preview.
enum FullscreenListeningMode {
  lyrics,
  audio,
}

/// Now Playing on the desktop, covering the whole window in Expanded Preview
/// or Fullscreen.
///
/// Features two dedicated listening modes:
/// - Cover + Lyrics: Stage on the leading side, synchronized lyrics on the trailing side.
/// - Cover + Audio: Audio Control Center (live monitor + quick settings) on the
///   left-centre, Stage on the right side.
///
/// Switching modes preserves playback continuity and respects dismissal priorities.
class DesktopNowPlaying extends ConsumerStatefulWidget {
  const DesktopNowPlaying({
    super.key,
    this.metadataControllerFactory,
    this.initialMode,
  });

  final PlayerMetadataController Function()? metadataControllerFactory;
  final FullscreenListeningMode? initialMode;

  @override
  ConsumerState<DesktopNowPlaying> createState() => _DesktopNowPlayingState();
}

class _DesktopNowPlayingState extends ConsumerState<DesktopNowPlaying> {
  late final _metadata =
      widget.metadataControllerFactory?.call() ?? PlayerMetadataController();
  final _seekPreview = PlaybackSeekPreview();
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaItemSub;
  late final LyricsTranslationController _lyricsTranslation;

  late FullscreenListeningMode _mode;
  bool _panelOpen = true;
  DesktopInspectorPanel? _lastPanel;

  @override
  void initState() {
    super.initState();
    _lyricsTranslation = ref.read(lyricsTranslationProvider.notifier);

    if (widget.initialMode != null) {
      _mode = widget.initialMode!;
      _panelOpen = true;
      if (_mode == FullscreenListeningMode.audio) {
        desktopLiveAudioMonitorOpen.value = true;
      }
    } else {
      final panel = desktopInspectorPanel.value;
      if (panel == DesktopInspectorPanel.lyrics) {
        _mode = FullscreenListeningMode.lyrics;
        _panelOpen = true;
        _lastPanel = DesktopInspectorPanel.lyrics;
      } else if (panel == DesktopInspectorPanel.upNext) {
        _mode = FullscreenListeningMode.lyrics;
        _panelOpen = true;
        _lastPanel = DesktopInspectorPanel.upNext;
      } else {
        _mode = FullscreenListeningMode.lyrics;
        _panelOpen = false;
        _lastPanel = null;
      }
    }

    desktopInspectorPanel.addListener(_onInspectorPanelChanged);

    _mediaItemSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (previous, next) {
        if (previous?.value?.id != next.value?.id) _seekPreview.reset();
        if (previous?.value?.id == next.value?.id && previous != null) return;
        unawaited(
          _metadata.load(next.value, inspectUnresolvedContentUri: true),
        );
      },
      fireImmediately: true,
    );
  }

  void _onInspectorPanelChanged() {
    final panel = desktopInspectorPanel.value;
    if (panel != null) {
      setState(() {
        _mode = FullscreenListeningMode.lyrics;
        _panelOpen = true;
        _lastPanel = panel;
      });
    } else if (widget.initialMode == null) {
      setState(() {
        _panelOpen = false;
      });
    }
  }

  void _setMode(FullscreenListeningMode targetMode) {
    setState(() {
      _mode = targetMode;
      _panelOpen = true;
      if (targetMode == FullscreenListeningMode.audio) {
        desktopLiveAudioMonitorOpen.value = true;
        desktopInspectorPanel.value = null;
      } else {
        desktopLiveAudioMonitorOpen.value = false;
        desktopInspectorPanel.value = DesktopInspectorPanel.lyrics;
        _lastPanel = DesktopInspectorPanel.lyrics;
      }
    });
  }

  @override
  void dispose() {
    desktopInspectorPanel.removeListener(_onInspectorPanelChanged);
    _mediaItemSub?.close();
    _lyricsTranslation.cancel(owner: this);
    _metadata.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  /// Centers the top buttons on the traffic lights' row.
  static const double _controlsTop = (desktopTitleBarHeight - 36) / 2;

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (context.isMornye) return _buildPlayer(context, mediaItem);
    return PlayerArtworkTheme(
      artUri: mediaItem?.artUri?.toString(),
      child: Builder(builder: (context) => _buildPlayer(context, mediaItem)),
    );
  }

  Widget _buildPlayer(BuildContext context, MediaItem? mediaItem) {
    final mornye = context.isMornye;
    final theme = mornye
        ? MornyeTheme.fromContext(context, brightness: Brightness.dark)
        : Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Theme(
      data: theme,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (mornye)
              MornyePlayerBackground(artUri: mediaItem?.artUri)
            else if (mediaItem != null)
              MaterialPlayerBackdrop(
                mediaItem: mediaItem,
                colorScheme: colorScheme,
                showArtwork: false,
              )
            else
              ColoredBox(color: colorScheme.surface),
            if (mediaItem == null)
              Center(
                child: Text(
                  context.l10n.nowPlayingNothingPlaying,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              _layout(context, mediaItem, colorScheme),
            // The player covers the title bar row, so it drags the window.
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: desktopTitleBarHeight,
              child: DesktopWindowDragArea(zoomOnDoubleClick: true),
            ),
            // The close button follows the traffic lights, which hide in
            // full screen.
            ValueListenableBuilder<bool>(
              valueListenable: desktopWindowFullScreen,
              builder: (context, fullScreen, button) => PositionedDirectional(
                top: _controlsTop,
                start: desktopTitleBarInContentFor(context) && !fullScreen
                    ? desktopWindowControlsWidth + 12
                    : 20,
                child: button!,
              ),
              child: _RoundButton(
                key: const ValueKey('desktop-now-playing-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: mornye ? CupertinoIcons.xmark : Icons.close,
                onPressed: closeDesktopNowPlaying,
              ),
            ),
            PositionedDirectional(
              top: _controlsTop,
              end: 20,
              width: 260,
              child: _Capsule(
                child: PlayerVolumeControl(
                  foreground: mornye ? Colors.white : colorScheme.onSurface,
                ),
              ),
            ),
            PositionedDirectional(
              bottom: 20,
              end: 20,
              child: _Capsule(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RoundButton(
                      key: const ValueKey('desktop-now-playing-lyrics-toggle'),
                      tooltip: context.l10n.nowPlayingTabLyrics,
                      icon: mornye
                          ? CupertinoIcons.quote_bubble
                          : Icons.lyrics_outlined,
                      selected: _panelOpen && _mode == FullscreenListeningMode.lyrics,
                      onPressed: () => _setMode(FullscreenListeningMode.lyrics),
                    ),
                    const SizedBox(width: 4),
                    _RoundButton(
                      key: const ValueKey('desktop-now-playing-audio-toggle'),
                      tooltip: 'Audio Control Center',
                      icon: mornye
                          ? CupertinoIcons.slider_horizontal_3
                          : Icons.tune,
                      selected: _panelOpen && _mode == FullscreenListeningMode.audio,
                      onPressed: () => _setMode(FullscreenListeningMode.audio),
                    ),
                    const SizedBox(width: 4),
                    ValueListenableBuilder<bool>(
                      valueListenable: desktopWindowFullScreen,
                      builder: (context, fullScreen, _) => _RoundButton(
                        key: const ValueKey(
                          'desktop-now-playing-fullscreen-toggle',
                        ),
                        tooltip: fullScreen
                            ? MaterialLocalizations.of(context).closeButtonTooltip
                            : context.l10n.desktopWindowFullscreen,
                        icon: fullScreen
                            ? (mornye
                                ? CupertinoIcons.fullscreen_exit
                                : Icons.fullscreen_exit)
                            : (mornye
                                ? CupertinoIcons.fullscreen
                                : Icons.fullscreen),
                        selected: fullScreen,
                        onPressed: toggleDesktopFullScreen,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _layout(
    BuildContext context,
    MediaItem mediaItem,
    ColorScheme colorScheme,
  ) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final motion = _panelOpen
        ? desktopInspectorMotion(context)
        : const AppMotionSpec(Duration(milliseconds: 260), Curves.easeInCubic);
    return LayoutBuilder(
      builder: (context, constraints) => TweenAnimationBuilder<double>(
        tween: Tween(end: _panelOpen ? 1.0 : 0.0),
        duration: reduce ? Duration.zero : motion.duration,
        curve: motion.curve,
        onEnd: () {
          if (!_panelOpen && mounted) setState(() => _lastPanel = null);
        },
        builder: (context, progress, _) =>
            _sideLayout(context, constraints, mediaItem, colorScheme, progress),
      ),
    );
  }

  /// The two listening layouts:
  /// - Lyrics: Stage on the leading 5/11, lyrics / queue on the trailing 6/11.
  /// - Audio: Audio Control Center at LEFT-CENTRE, Stage on the right.
  Widget _sideLayout(
    BuildContext context,
    BoxConstraints constraints,
    MediaItem mediaItem,
    ColorScheme colorScheme,
    double progress,
  ) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final size = progress.clamp(0.0, 1.0);

    final isAudio = _mode == FullscreenListeningMode.audio;
    final isLyrics = _mode == FullscreenListeningMode.lyrics;
    final showsLyrics = isLyrics && _lastPanel != DesktopInspectorPanel.upNext;
    final showsUpNext = isLyrics && _lastPanel == DesktopInspectorPanel.upNext;

    // Responsive side panel width for Audio Control Center
    const double maxPanelWidth = 390.0;
    final double panelWidth = width >= 1000
        ? maxPanelWidth
        : math.max(280.0, math.min(maxPanelWidth, width * 0.38));

    final double leading = width * 5 / 11;
    const double panelMargin = 28.0;
    const double panelGap = 24.0;

    // Audio module placed around LEFT-CENTRE of the fullscreen layout
    final double audioPanelStart = math.max(
      panelMargin,
      (leading - panelWidth) / 2,
    );

    final double remainingStageWidth = math.max(
      280.0,
      width - (audioPanelStart + panelWidth + panelGap) - panelMargin,
    );

    // Stage center depending on active mode:
    // When Audio active: stage is on the right of Audio panel
    // When Lyrics active: stage is on the left 5/11 of the screen
    final double sideStageCenterX = isAudio
        ? (audioPanelStart + panelWidth + panelGap) + remainingStageWidth / 2
        : leading / 2;

    final double centerX = lerpDouble(width / 2, sideStageCenterX, size)!;

    // Column width calculation respecting height and transport constraints
    double columnWidthFor(double limit, double containerLimit) {
      final available = math.max(280.0, math.min(limit, containerLimit));
      return math.max(280.0, math.min(available, height - 310.0));
    }

    final double fullWidthLimit = columnWidthFor(520.0, width - 64.0);
    final double lyricsWidthLimit = columnWidthFor(
      math.min(440.0, width * 0.34),
      leading - 32.0,
    );
    final double audioWidthLimit = columnWidthFor(
      440.0,
      remainingStageWidth - 32.0,
    );

    final double sideLimit = isAudio ? audioWidthLimit : lyricsWidthLimit;
    final double columnWidth = lerpDouble(fullWidthLimit, sideLimit, size)!;

    final rtl = Directionality.of(context) == TextDirection.rtl;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final slide = ((1.0 - size) * 48.0 * pixelRatio).roundToDouble() / pixelRatio;

    final player = SizedBox(
      width: columnWidth,
      child: _PlayerColumn(
        mediaItem: mediaItem,
        metadata: _metadata,
        seekPreview: _seekPreview,
        colorScheme: colorScheme,
        artworkSize: columnWidth,
        decodeSize: columnWidthFor(520.0, width),
      ),
    );

    final switchDuration = MediaQuery.disableAnimationsOf(context) || size < 0.5
        ? Duration.zero
        : const Duration(milliseconds: 180);

    return Stack(
      children: [
        // Main Now Playing stage (artwork, title, badges, controls)
        Positioned.directional(
          textDirection: Directionality.of(context),
          start: centerX - columnWidth / 2,
          top: 0,
          bottom: 0,
          width: columnWidth,
          child: Center(child: player),
        ),

        // Synchronized Lyrics or Up Next on trailing region
        if (!isAudio)
          PositionedDirectional(
            start: leading,
            end: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: size < 0.5,
              child: ExcludeFocus(
                excluding: size == 0,
                child: Opacity(
                  opacity: size,
                  child: Transform.translate(
                    offset: Offset(slide * (rtl ? -1 : 1), 0),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        0,
                        72,
                        48,
                        80,
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          IgnorePointer(
                            key: const ValueKey('desktop-now-playing-lyrics'),
                            ignoring: !showsLyrics,
                            child: ExcludeFocus(
                              excluding: !showsLyrics,
                              child: AnimatedOpacity(
                                opacity: showsLyrics ? 1.0 : 0.0,
                                duration: switchDuration,
                                child: NoScrollbars(
                                  child: KeyedSubtree(
                                    key: const ValueKey(
                                      'desktop-contextual-lyrics-view',
                                    ),
                                    child: PlayerLyricsSection(
                                      metadata: _metadata,
                                      seekPreview: _seekPreview,
                                      colorScheme: colorScheme,
                                      isActive: true,
                                      animateWords: showsLyrics && size > 0.5,
                                      options: LyricsOptionsButton(
                                        metadata: _metadata,
                                        colorScheme: colorScheme,
                                        translationOwner: this,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          AnimatedSwitcher(
                            duration: switchDuration,
                            child: showsUpNext
                                ? KeyedSubtree(
                                    key: const ValueKey(
                                      'desktop-now-playing-upNext',
                                    ),
                                    child: NoScrollbars(
                                      child: context.isMornye
                                          ? MornyePlayerQueue(
                                              colorScheme: colorScheme,
                                            )
                                          : DesktopMaterialQueue(
                                              colorScheme: colorScheme,
                                            ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

        // Audio Control Center on LEFT-CENTRE
        if (isAudio)
          PositionedDirectional(
            key: const ValueKey('desktop-contextual-audio-positioned'),
            start: audioPanelStart,
            top: 72.0,
            bottom: 80.0,
            width: panelWidth,
            child: IgnorePointer(
              ignoring: size < 0.5,
              child: ExcludeFocus(
                excluding: size == 0,
                child: Opacity(
                  opacity: size,
                  child: Transform.translate(
                    offset: Offset(-slide * (rtl ? -1 : 1), 0),
                    child: KeyedSubtree(
                      key: const ValueKey('desktop-contextual-audio-view'),
                      child: _AudioControlCenterSideView(
                        onClose: () => _setMode(FullscreenListeningMode.lyrics),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Audio Control Center side panel in Fullscreen / Expanded Preview.
/// Displays the Live Audio Stream Monitor stacked directly above Audio Quick Settings
/// with a 10px vertical gap, both sharing matching widths and acrylic glass styling.
class _AudioControlCenterSideView extends StatelessWidget {
  const _AudioControlCenterSideView({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: desktopLiveAudioMonitorOpen,
      builder: (context, monitorOpen, _) {
        return SingleChildScrollView(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (monitorOpen) ...[
                WindowsLiveAudioMonitorCard(
                  key: const ValueKey('desktop-fullscreen-live-audio-monitor'),
                  isFloating: false,
                  onDismiss: closeDesktopLiveAudioMonitor,
                ),
                const SizedBox(height: 10),
              ],
              WindowsAudioQuickSettingsPanel(
                key: const ValueKey('desktop-fullscreen-audio-quick-settings'),
                onClose: onClose,
                showCloseButton: false,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlayerColumn extends StatelessWidget {
  const _PlayerColumn({
    required this.mediaItem,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.artworkSize,
    required this.decodeSize,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final double artworkSize;

  /// The width the cover is decoded at, at least [artworkSize].
  final double decodeSize;

  @override
  Widget build(BuildContext context) {
    final mornye = context.isMornye;
    final textTheme = Theme.of(context).textTheme;
    final corners = BorderRadius.circular(mornye ? 12 : 28);
    final artwork = PlayerArtwork(
      artUri: mediaItem.artUri?.toString(),
      colorScheme: colorScheme,
      iconSize: 96,
      cacheWidth: (decodeSize * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    final subtitle = [
      mediaItem.artist,
      mediaItem.album,
    ].whereType<String>().where((part) => part.trim().isNotEmpty).join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox.square(
          dimension: artworkSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: corners,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 28,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: mornye
                ? ClipRSuperellipse(borderRadius: corners, child: artwork)
                : ClipRRect(borderRadius: corners, child: artwork),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlayerMetadataTitle(
                    mediaItem: mediaItem,
                    metadata: metadata,
                    style:
                        (mornye ? textTheme.titleMedium : textTheme.titleLarge)
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                    maxLines: 1,
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (mornye ? textTheme.bodyMedium : textTheme.titleSmall)
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (mornye)
              MornyePlayerFavoriteButton(
                mediaItem: mediaItem,
                color: colorScheme.onSurface,
                iconSize: 20,
              ),
          ],
        ),
        // Live audio output monitor / format telemetry badge
        _AudioBadgeRow(mediaItem: mediaItem, metadata: metadata),
        PlayerPlaybackControls(
          key: ValueKey(mediaItem.id),
          mediaId: mediaItem.id,
          duration: mediaItem.duration ?? Duration.zero,
          seekPreview: seekPreview,
          colorScheme: colorScheme,
          metadata: metadata,
          compact: true,
          edgeAligned: true,
        ),
      ],
    );
  }
}

/// Displays live stream telemetry or probed track format badges.
class _AudioBadgeRow extends StatelessWidget {
  const _AudioBadgeRow({
    required this.mediaItem,
    required this.metadata,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return ValueListenableBuilder<WindowsAudioStatus>(
      valueListenable: windowsAudioStatus,
      builder: (context, status, _) {
        final List<Widget> badges = [];

        if (status.isBitPerfect) {
          badges.add(
            _BadgeChip(
              text: 'BIT-PERFECT',
              highlight: true,
              color: colors.primary,
            ),
          );
        }

        if (status.sampleRate != null && status.sampleRate! > 0) {
          final rateStr = status.sampleRate! >= 1000
              ? '${(status.sampleRate! / 1000).toStringAsFixed(status.sampleRate! % 1000 == 0 ? 0 : 1)} kHz'
              : '${status.sampleRate} Hz';
          final bitsStr = status.bitDepth != null && status.bitDepth! > 0
              ? '${status.bitDepth}-bit'
              : '';
          final text = [rateStr, bitsStr].where((s) => s.isNotEmpty).join(' · ');
          badges.add(_BadgeChip(text: text));
        } else if (metadata.metadata != null) {
          final m = metadata.metadata!;
          final codec = m['codec']?.toString().toUpperCase() ?? '';
          final rate = m['sample_rate'] != null
              ? '${((m['sample_rate'] as num) / 1000).toStringAsFixed(1)} kHz'
              : '';
          final text = [codec, rate].where((s) => s.isNotEmpty).join(' · ');
          if (text.isNotEmpty) {
            badges.add(_BadgeChip(text: text));
          }
        }

        if (badges.isEmpty) return const SizedBox(height: 6);

        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: badges,
          ),
        );
      },
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({
    required this.text,
    this.highlight = false,
    this.color,
  });

  final String text;
  final bool highlight;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = color ?? colors.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: highlight
            ? accent.withValues(alpha: 0.16)
            : colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlight
              ? accent.withValues(alpha: 0.45)
              : colors.outlineVariant.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: highlight ? FontWeight.w700 : FontWeight.w600,
          letterSpacing: 0.3,
          color: highlight ? accent : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = context.isMornye
        ? Colors.white.withValues(alpha: 0.12)
        : scheme.surfaceContainerHigh.withValues(alpha: 0.72);
    return DecoratedBox(
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Padding(padding: const EdgeInsets.all(4), child: child),
    );
  }
}

/// A round icon button over the artwork backdrop; [selected] fills it.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (context.isMornye) {
      return Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          child: CupertinoButton(
            minimumSize: const Size.square(36),
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(18),
            color: selected
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.12),
            onPressed: onPressed,
            child: AppIcon(
              icon,
              size: 18,
              color: selected ? Colors.black : Colors.white,
            ),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: tooltip,
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        foregroundColor: selected
            ? scheme.onSecondaryContainer
            : scheme.onSurfaceVariant,
      ),
      icon: AppIcon(icon),
      onPressed: onPressed,
    );
  }
}
