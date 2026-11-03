import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/services/windows_audio_device_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/desktop/windows_audio_quick_settings.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeMusicController implements MusicPlayerController {
  final List<String> calls = [];

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');

  @override
  Future<void> next() async => calls.add('next');

  @override
  Future<void> previous() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async => calls.add('seek');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestSettingsNotifier extends SettingsNotifier {
  _TestSettingsNotifier(this.initial);
  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

const _testTrack = MediaItem(
  id: 'test-track-1',
  title: 'Bit-Perfect Symphony',
  artist: 'Audiophile Master',
  album: 'High-Res Audio Album',
  duration: Duration(minutes: 5, seconds: 20),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDesktopPlatformOverride = true;
    desktopNowPlayingOpen.value = true;
    desktopInspectorPanel.value = null;
    desktopLiveAudioMonitorOpen.value = false;
    windowsAudioStatus.value = const WindowsAudioStatus(
      reason: 'active',
      mode: 'exclusive_event',
      activeDevice: 'DAC High Resolution Audio',
      isBitPerfect: true,
      sampleRate: 96000,
      bitDepth: 24,
      channels: 'stereo',
      channelCount: 2,
      format: 'float',
      bitPerfectReason: 'Bit-perfect direct output',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.zarz.mornye/windows_audio'),
          (MethodCall call) async {
            if (call.method == 'getAudioEndpoints') {
              return [
                {
                  'endpointId': '{dac-endpoint-guid}',
                  'mpvDeviceId': 'wasapi/{dac-endpoint-guid}',
                  'guid': '{dac-endpoint-guid}',
                  'name': 'DAC High Resolution Audio',
                  'isDefault': true,
                  'state': 1,
                  'mixSampleRate': 96000,
                  'mixBitDepth': 24,
                  'mixChannels': 2,
                  'mixFormat': 'float',
                  'id': 'wasapi/{dac-endpoint-guid}',
                },
              ];
            }
            return null;
          },
        );
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    desktopNowPlayingOpen.value = false;
    desktopInspectorPanel.value = null;
    desktopLiveAudioMonitorOpen.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.zarz.mornye/windows_audio'),
          null,
        );
  });

  Widget createTestWidget({
    bool mornye = false,
    FullscreenListeningMode? initialMode,
    MusicPlayerController? controller,
    Size size = const Size(1400, 900),
  }) {
    final fakeController = controller ?? _FakeMusicController();
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => _TestSettingsNotifier(
            const AppSettings(
              windowsOutputMode: 'exclusive_event',
              windowsOutputDevice: 'wasapi/{dac-endpoint-guid}',
            ),
          ),
        ),
        musicPlayerControllerProvider.overrideWithValue(fakeController),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => Stream.value(_testTrack),
        ),
        playbackStateProvider.overrideWith(
          (ref) => Stream.value(
            PlaybackState(
              playing: true,
              processingState: AudioProcessingState.ready,
              updatePosition: const Duration(seconds: 45),
            ),
          ),
        ),
        playQueueProvider.overrideWith(
          (ref) => Stream.value(const [_testTrack]),
        ),
        systemVolumeProvider.overrideWith((ref) => Stream.value(0.85)),
      ],
      child: MaterialApp(
        theme: mornye
            ? MornyeTheme.build(Brightness.dark)
            : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DesktopNowPlaying(
            initialMode: initialMode,
            metadataControllerFactory: () => PlayerMetadataController(
              readMetadata: (_) async => {
                'codec': 'FLAC',
                'sample_rate': 96000,
                'bits_per_raw_sample': 24,
              },
            ),
          ),
        ),
      ),
    );
  }

  group('Two-Mode Fullscreen Listening Architecture', () {
    test('strictly defines exactly two listening modes without coverOnly', () {
      expect(FullscreenListeningMode.values, [
        FullscreenListeningMode.lyrics,
        FullscreenListeningMode.audio,
      ]);
      expect(FullscreenListeningMode.values.length, 2);
    });
  });

  group('Cover + Lyrics Mode Presentation', () {
    testWidgets('renders stage on leading side and lyrics section on trailing side', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        createTestWidget(
          mornye: false,
          initialMode: FullscreenListeningMode.lyrics,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PlayerLyricsSection), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-contextual-audio-view')), findsNothing);

      // Verify stage is on the leading half (dx < 1400 * 0.45)
      final controlsFinder = find.byType(PlayerPlaybackControls);
      expect(controlsFinder, findsOneWidget);
      final stageCenter = tester.getCenter(controlsFinder);
      expect(stageCenter.dx, lessThan(1400 * 0.45));

      // Verify lyrics is on the trailing half (dx > 1400 * 0.45)
      final lyricsCenter = tester.getCenter(find.byType(PlayerLyricsSection));
      expect(lyricsCenter.dx, greaterThan(1400 * 0.45));

      // Bottom capsule mode buttons state
      final lyricsToggle = tester.widget(
        find.byKey(const ValueKey('desktop-now-playing-lyrics-toggle')),
      );
      expect((lyricsToggle as dynamic).selected, isTrue);

      final audioToggle = tester.widget(
        find.byKey(const ValueKey('desktop-now-playing-audio-toggle')),
      );
      expect((audioToggle as dynamic).selected, isFalse);
    });
  });

  group('Cover + Audio Mode Presentation and Left-Centre Placement', () {
    testWidgets(
      'positions Audio module around left-centre and stage shifted to the right',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          createTestWidget(
            mornye: false,
            initialMode: FullscreenListeningMode.audio,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Audio side view is mounted
        final audioView = find.byKey(
          const ValueKey('desktop-contextual-audio-view'),
        );
        expect(audioView, findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-fullscreen-live-audio-monitor')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('desktop-fullscreen-audio-quick-settings')),
          findsOneWidget,
        );

        // Bounding box: Audio module is in the left-centre (dx in [100, 500])
        final audioCenter = tester.getCenter(audioView);
        expect(audioCenter.dx, greaterThan(100.0));
        expect(audioCenter.dx, lessThan(1400 * 0.45));

        // Now Playing stage is shifted to the right of the Audio module
        final controlsFinder = find.byType(PlayerPlaybackControls);
        expect(controlsFinder, findsOneWidget);
        final stageCenter = tester.getCenter(controlsFinder);
        expect(stageCenter.dx, greaterThan(audioCenter.dx + 250.0));
        expect(stageCenter.dx, greaterThan(1400 * 0.5));

        // Bottom capsule shows Audio mode selected
        final audioToggle = tester.widget(
          find.byKey(const ValueKey('desktop-now-playing-audio-toggle')),
        );
        expect((audioToggle as dynamic).selected, isTrue);

        final lyricsToggle = tester.widget(
          find.byKey(const ValueKey('desktop-now-playing-lyrics-toggle')),
        );
        expect((lyricsToggle as dynamic).selected, isFalse);
      },
    );

    testWidgets('renders Audio module properly in Mornye Cupertino theme', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        createTestWidget(
          mornye: true,
          initialMode: FullscreenListeningMode.audio,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey('desktop-contextual-audio-view')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('desktop-now-playing-audio-toggle')),
        findsOneWidget,
      );
    });
  });

  group('Mode Switching Continuity & Playback Invariance', () {
    testWidgets(
      'toggling modes preserves playback controls, timeline and controller across switches',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final fakeController = _FakeMusicController();

        await tester.pumpWidget(
          createTestWidget(
            mornye: false,
            initialMode: FullscreenListeningMode.lyrics,
            controller: fakeController,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Initial mode: Lyrics
        expect(find.byType(PlayerLyricsSection), findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-contextual-audio-view')),
          findsNothing,
        );

        // Get identity of the PlayerPlaybackControls state
        final initialControlsState = tester.state(
          find.byType(PlayerPlaybackControls),
        );

        // Switch to Audio mode
        await tester.tap(
          find.byKey(const ValueKey('desktop-now-playing-audio-toggle')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Audio view is now mounted
        expect(
          find.byKey(const ValueKey('desktop-contextual-audio-view')),
          findsOneWidget,
        );

        // PlayerPlaybackControls remained continuously mounted with identical state
        final audioModeControls = find.byType(PlayerPlaybackControls);
        expect(audioModeControls, findsOneWidget);
        expect(tester.state(audioModeControls), same(initialControlsState));

        // Switch back to Lyrics mode
        await tester.tap(
          find.byKey(const ValueKey('desktop-now-playing-lyrics-toggle')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Lyrics is back
        expect(find.byType(PlayerLyricsSection), findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-contextual-audio-view')),
          findsNothing,
        );

        // Playback was completely uninterrupted (no spurious stops/re-seeks)
        expect(tester.state(audioModeControls), same(initialControlsState));
        expect(fakeController.calls, isEmpty);
      },
    );
  });

  group('Live Audio Output Badges on Player Stage', () {
    testWidgets(
      'displays BIT-PERFECT and high-res format badges under track title',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          createTestWidget(
            mornye: false,
            initialMode: FullscreenListeningMode.lyrics,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('BIT-PERFECT'), findsOneWidget);
        expect(find.text('96 kHz · 24-bit'), findsOneWidget);
      },
    );
  });

  group('Responsive Screen Layouts', () {
    testWidgets('adapts smoothly to 800-wide narrow desktop layout without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        createTestWidget(
          mornye: false,
          initialMode: FullscreenListeningMode.audio,
          size: const Size(800, 600),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const ValueKey('desktop-contextual-audio-view')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Escape Dismissal and Window Mode', () {
    testWidgets('close button dismisses Now Playing layer', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      expect(desktopNowPlayingOpen.value, isTrue);

      await tester.pumpWidget(
        createTestWidget(
          mornye: false,
          initialMode: FullscreenListeningMode.audio,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('desktop-now-playing-close')));
      await tester.pump();

      expect(desktopNowPlayingOpen.value, isFalse);
    });
  });
}
