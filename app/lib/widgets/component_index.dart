// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Regenerate with `./build.sh gen-components` (macOS) or
// `.\build.ps1 gen-components` (Windows). Metadata comes from
// app/design/components.json; the usedIn map is read out of
// app/lib/ by scripts/gen_component_index.py. CI fails the
// build if this file drifts from either.

import 'component_info.dart';

/// Every component the Theme Gallery documents, by class name.
const Map<String, ComponentInfo> kComponentIndex = {
  'AppButton': ComponentInfo(
    name: 'AppButton',
    declaredIn: 'lib/widgets/app_button.dart',
    summary:
        'The app\'s text button, one drawing in every theme: a box at radiusSm in two sizes (36 px regular with a fontHeading label, 28 px compact with fontSmall) and four roles. Standard is a borderStrong rim in textPrimary; affirmative is accentFill under accentInk, one per dialog footer; destructive is the rim with an errorRed label; quiet has no rim and a textSecondary label, for the cancel beside an affirmative. Hover and press tint the face in the ink, focus takes the rim, disabled dims the ink to 40%. Built on ChromePressable, not Material, so the desktop visual density does not resize it. The landing card\'s entry buttons, every dialog footer and alert action, and the inline actions in settings, the mix view and the renderer view are this widget.',
    usedIn: {
      'lib/export/iamf_export_dialog.dart': 7,
      'lib/import/adm_import_flow.dart': 7,
      'lib/views/mix_view.dart': 4,
      'lib/widgets/ok_dialog.dart': 3,
      'lib/widgets/routing_matrix_dialog.dart': 3,
      'lib/widgets/settings_dialog.dart': 3,
      'lib/workspace/workspace_close.dart': 3,
      'lib/views/element_card.dart': 2,
      'lib/widgets/element_format_dialog.dart': 2,
      'lib/widgets/safety_notice_dialog.dart': 2,
      'lib/import/adm_probe_inspector.dart': 1,
      'lib/loudness/loudness_report_dialog.dart': 1,
      'lib/loudness/loudness_report_widgets.dart': 1,
      'lib/loudness/qc_loudness_report_dialog.dart': 1,
      'lib/views/renderer_view.dart': 1,
      'lib/views/routing_matrix_view.dart': 1,
      'lib/widgets/dialog_shell.dart': 1,
      'lib/widgets/viz_panel.dart': 1,
      'lib/workspace/landing_screen.dart': 1,
    },
    useCount: 45,
  ),
  'ConsoleToggle': ComponentInfo(
    name: 'ConsoleToggle',
    declaredIn: 'lib/widgets/console_widgets.dart',
    summary:
        'Two-state switch for booleans that apply immediately, with no confirm step.',
    usedIn: {
      'lib/widgets/settings_dialog.dart': 2,
      'lib/views/renderer_view.dart': 1,
    },
    useCount: 3,
  ),
  'ConsoleSegment': ComponentInfo(
    name: 'ConsoleSegment',
    declaredIn: 'lib/widgets/console_widgets.dart',
    summary:
        'Segmented row for a small closed set of choices. Every instance in Settings shares one measured width (ConsoleSegment.uniformWidth), so a long label in any of them widens all - see console_segment_width_test.',
    usedIn: {
      'lib/widgets/settings_dialog.dart': 4,
      'lib/loudness/loudness_report_dialog.dart': 1,
      'lib/loudness/qc_loudness_report_dialog.dart': 1,
    },
    useCount: 6,
  ),
  'OptionGrid': ComponentInfo(
    name: 'OptionGrid',
    declaredIn: 'lib/widgets/option_grid.dart',
    summary:
        'A closed set of choices as a grid of 24 px buttons that fills its width, one selected: rows of equal-width buttons, the column count from the width and the widest label at the current font size, so every label fits on one line. Each button is a ConsoleChip: the selected one a flat accentFill with no rim under an accentInk label, the others the theme\'s button face. An unavailable option dims its face to 40% and takes no input; its label stays readable. The Renderer view\'s output targets are one.',
    usedIn: {'lib/views/renderer_view.dart': 1},
    useCount: 1,
  ),
  'ConsoleChip': ComponentInfo(
    name: 'ConsoleChip',
    declaredIn: 'lib/widgets/console_chip.dart',
    summary:
        'A 24 px chip, selected or not, with any content: the drawing of each OptionGrid button, and the Mix view\'s mix presentation tabs, layout chips and add buttons. Selected marks a chosen thing (the active monitoring target, the active mix presentation): a flat accentFill with no rim under a w600 accentInk label, the affirmative AppButton\'s colours, in every theme. Plain marks a choice that can be clicked, or without onTap a label such as a tagged layout, in the theme\'s button face: Dark\'s raised face, Light\'s lifted RaisedFace, Classic\'s recessedWell, High Contrast\'s borderStrong outline. With onTap it is a ChromePressable with hover, press and focus drawings and a semanticLabel; without, a label at rest announced by its content. A disabled chip dims its face to 40% and keeps its label readable.',
    usedIn: {'lib/views/mix_view.dart': 3, 'lib/widgets/option_grid.dart': 1},
    useCount: 4,
  ),
  'StatusTag': ComponentInfo(
    name: 'StatusTag',
    declaredIn: 'lib/widgets/status_tag.dart',
    summary:
        'A small tag that names a state or a kind, one geometry for all: a fontCaption w600 label with 0.5 tracking, 5 by 2 px of padding at radiusSm, after an optional 11 px icon, the label\'s case kept. The ink is the caller\'s colour and the fill that colour at 12%, or textTertiary on bgControls when no colour is given; an outlined tag draws a 1 px rim at 60% and no fill. The loudness bar\'s LIVE, MOMENTARY, SHORT-TERM and TRUE PEAK, the Visualizers panel\'s EXPERIMENTAL, the Playback inspector\'s SELECTED, the Loudness Report\'s IAMF and MON, and the Most common, Coming soon and YouTube tags are this widget.',
    usedIn: {
      'lib/views/renderer_view.dart': 2,
      'lib/export/iamf_export_dialog.dart': 1,
      'lib/loudness/loudness_report_widgets.dart': 1,
      'lib/views/inspector_view.dart': 1,
      'lib/widgets/element_format_dialog.dart': 1,
      'lib/widgets/viz_panel.dart': 1,
      'lib/widgets/youtube_support_badge.dart': 1,
    },
    useCount: 8,
  ),
  'ConsoleSelector': ComponentInfo(
    name: 'ConsoleSelector',
    declaredIn: 'lib/widgets/console_widgets.dart',
    summary:
        'Dropdown select for a list too long for a segmented row. Which control it draws is the theme\'s choice (ControlStyle): filled is a 24 px controlBg fill at radiusSm inside a 1 px border rim (Dark and Light); well is a 24 px well sunk into the panel with a chromeRimDark line along its top inside edge (Classic); outlined is a 24 px controlBg box with a borderStrong border at radiusSm (High Contrast). Each has a controlFg label and caret. The top bar\'s mix presentation switcher is a ConsoleSelector, 180 px wide in every theme.',
    usedIn: {
      'lib/export/iamf_export_dialog.dart': 3,
      'lib/views/mix_view.dart': 3,
      'lib/widgets/settings_dialog.dart': 3,
      'lib/widgets/topbar.dart': 2,
      'lib/import/adm_import_flow.dart': 1,
      'lib/widgets/profile_selector.dart': 1,
      'lib/widgets/routing_matrix_dialog.dart': 1,
    },
    useCount: 14,
  ),
  'ConsoleLed': ComponentInfo(
    name: 'ConsoleLed',
    declaredIn: 'lib/widgets/console_widgets.dart',
    summary:
        'Small status indicator. Reads indicatorGreen rather than typeObject, so changing the element-type palette does not recolour every LED.',
    usedIn: {},
    useCount: 0,
  ),
  'GainKnob': ComponentInfo(
    name: 'GainKnob',
    declaredIn: 'lib/widgets/gain_knob.dart',
    summary:
        'Every knob in the app, and the only one placed by hand. Which instrument it draws is the theme\'s choice (KnobStyle): Dark\'s brushed disc, Light\'s Knob_a, and in knob_line_painters.dart Classic\'s bar knob (a cap in the dish with a bar across it) and High Contrast\'s outlined ring. Every knob turns through the same 270-degree sweep and shares one drag and double-tap, KnobGestures in knob_a.dart. The drawings read bgDeep, bgControls/bgHover, borderStrong, purple and the text ramp at once, so a flat swatch cannot show whether a theme keeps the knob legible.',
    usedIn: {'lib/views/elements_view.dart': 1, 'lib/views/mix_view.dart': 1},
    useCount: 2,
  ),
  'KnobA': ComponentInfo(
    name: 'KnobA',
    declaredIn: 'lib/widgets/knob_a.dart',
    summary:
        'Light\'s knob: an accent-coloured body under a glare highlight, with the fill arc inside the rim. Not placed by hand any more - GainKnob delegates to it when the theme selects KnobStyle.knobA, so every knob in the app is one control.',
    usedIn: {'lib/widgets/gain_knob.dart': 1},
    useCount: 1,
  ),
  'GainSlider': ComponentInfo(
    name: 'GainSlider',
    declaredIn: 'lib/views/gain_slider.dart',
    summary:
        'Horizontal gain fader. Fills with a purple to purpleLight gradient.',
    usedIn: {},
    useCount: 0,
  ),
  'TransportControls': ComponentInfo(
    name: 'TransportControls',
    declaredIn: 'lib/widgets/transport_controls.dart',
    summary:
        'Play, stop, skip and loop cluster in the top bar, bound to the transport; the buttons are TransportButton and TransportPlayButton. Four drawings by ChromeStyle: Dark\'s chrome-less grey glyphs with a triangle in the accent purple; Light\'s raised faces and round play with blue glyphs, which press in while held; Classic\'s wells with a purple play glyph (recessed); High Contrast\'s 2 px white squares and a solid lavender play with a black glyph (outlined). Every style draws the 30 px button and 34 px play, 8 px apart.',
    usedIn: {'lib/widgets/topbar.dart': 1},
    useCount: 1,
  ),
  'TransportClock': ComponentInfo(
    name: 'TransportClock',
    declaredIn: 'lib/widgets/transport_clock.dart',
    summary:
        'The transport\'s position / duration readout in the top bar, in the monospace face with tabular figures, at fontBodyL in a 30 px box in every style. Four drawings by ChromeStyle: Dark\'s bare textValue text with a half-opacity slash; Light\'s 1 px chromeInk outline with chromeInk text; Classic\'s well (recessed) and High Contrast\'s 2 px chromeRimDark outline (outlined), both in textValue. The top bar binds it to the transport and the time-or-samples toggle, and reserves the width of the longest value the display mode shows (9:59:59.999, or ten sample digits), so the controls beside it keep their place.',
    usedIn: {'lib/widgets/topbar.dart': 1},
    useCount: 1,
  ),
  'VideoStrip': ComponentInfo(
    name: 'VideoStrip',
    declaredIn: 'lib/video/video_strip.dart',
    summary:
        'The video strip between the top bar and the timeline: ground, header with the file name and actions, and the picture or empty state. The header lies over the body in every layout, so the picture gets the whole height; collapsed, the header is the strip at 24 px. Two groundings by ChromeStyle: in Classic and High Contrast (recessed, outlined) the header has no fill or hairline and the body sits on its own ground; in Dark and Light (beveled, raised) one radial surface lies under both, Dark adding a top highlight. VideoPanel owns the drop target, picker, resize and video state and hands this its parts.',
    usedIn: {'lib/video/video_panel.dart': 1},
    useCount: 1,
  ),
  'VideoEmptyBody': ComponentInfo(
    name: 'VideoEmptyBody',
    declaredIn: 'lib/video/video_strip.dart',
    summary:
        'The strip\'s empty state: a 320 x 160 frameless DropZone area in every theme, an image glyph over the label and the format line, tinted with the accent while a file is dragged over it. Shorter strips shrink it and drop the format line first.',
    usedIn: {'lib/video/video_panel.dart': 1},
    useCount: 1,
  ),
  'TransportScrubBar': ComponentInfo(
    name: 'TransportScrubBar',
    declaredIn: 'lib/widgets/transport_scrub_bar.dart',
    summary:
        'Position bar with a draggable playhead. Its fill defaults to the accent gradient and callers can override it. While a Playback file\'s duration scan runs it draws an ANALYZING caption in fontCaption textGhost against its right edge in place of the track, and ignores gestures.',
    usedIn: {'lib/widgets/topbar.dart': 1},
    useCount: 1,
  ),
  'DropZone': ComponentInfo(
    name: 'DropZone',
    declaredIn: 'lib/widgets/drop_zone.dart',
    summary:
        'Target for dropping files, with an accent-tinted idle and active state. The area variant, the add-track slot below the tracks, has four drawings by ChromeStyle: Dark\'s bgElevated band between two bevel lines with a purple glyph and textGhost text; Light\'s bgSurface panel at radius 8 with a chromeTabOn glyph and textTertiary text; Classic\'s bgControls well in a 1.5 px border (recessed); High Contrast\'s 2 px borderStrong outline on bgBase (outlined). All are 80 px tall, against the 124 both concept frames draw.',
    usedIn: {
      'lib/views/elements_view.dart': 2,
      'lib/video/video_panel.dart': 1,
      'lib/video/video_strip.dart': 1,
    },
    useCount: 4,
  ),
  'WindowTitlebar': ComponentInfo(
    name: 'WindowTitlebar',
    declaredIn: 'lib/widgets/window_titlebar.dart',
    summary:
        'Custom window chrome above the top bar: TitlebarStrip over a drag region that fills the strip, which draws the surface and lines per ChromeStyle under a centred title that is the same in every theme: the macOS window title, system face at 13 px semibold, in chromeInk. beveled fills from chromeBg (the frame draws no fill of its own over the bar\'s surface); raised is Light\'s Title Bar, chromeBg under a chromeRimDark edge with a chromeRimLight highlight and no bottom line, so it reads as one surface with the top bar. recessed and outlined (Classic and High Contrast) are chromeBg with no line. On the landing page every theme draws the page\'s ground instead: Dark\'s glow, bgBase in the others. The title is centred on the window, or between the two sides when it does not fit there; on Windows the menu bar takes the left side and the caption buttons the right.',
    usedIn: {'lib/main.dart': 1},
    useCount: 1,
  ),
  'AppMenuBar': ComponentInfo(
    name: 'AppMenuBar',
    declaredIn: 'lib/widgets/app_menu_bar.dart',
    summary:
        'The application menu: the system menu bar on macOS; on Windows a Flutter-drawn FlutterMenuBar at the left of the window titlebar, its titles in chromeInk with the titlebar hover face (titlebarHoverFace) on every ground. The drop-down panels are ConsoleSelector\'s menu surface, controlBg inside a border at radiusSm with no shadow, with 28 px rows, textPrimary labels, textSecondary shortcuts and a bgHover row highlight. Material\'s MenuBar displays shortcuts without registering them, so a menu accelerator shown here may not fire on Windows.',
    usedIn: {'lib/main.dart': 1},
    useCount: 1,
  ),
  'Topbar': ComponentInfo(
    name: 'Topbar',
    declaredIn: 'lib/widgets/topbar.dart',
    summary:
        'Workspace tabs (TopbarTab), mix presentation select (MixPresentationLabel and ConsoleSelector), scrub bar (TransportScrubBar), transport (TransportControls) and time readout (TransportClock).',
    usedIn: {'lib/widgets/app_shell.dart': 1},
    useCount: 1,
  ),
  'TopbarTab': ComponentInfo(
    name: 'TopbarTab',
    declaredIn: 'lib/widgets/topbar_tab.dart',
    summary:
        'One workspace tab in the top bar. Which tab it draws is the theme\'s choice (ChromeStyle): beveled is Dark\'s accent label over an underline that fades in and out; raised is Light\'s button, a rimmed light face when active, pressing in while held, and a 2 px outline when not; recessed is Classic\'s 2 px purple bar lit in a well under the active label; outlined is High Contrast\'s solid chromeTabOn block with an accentFg label, where inactive tabs outline in white under the pointer. The label is fontBodyL in every style, at weight 400 when active and 300 when inactive, centred in a box the width of the active label so the row does not reflow on a switch.',
    usedIn: {'lib/widgets/topbar.dart': 1},
    useCount: 1,
  ),
  'MixPresentationLabel': ComponentInfo(
    name: 'MixPresentationLabel',
    declaredIn: 'lib/widgets/mix_presentation_label.dart',
    summary:
        'The label beside the top bar\'s mix presentation switcher. Dark (beveled) and Light (raised) draw MIX PRESENTATION at fontSmall in chromeInk, tracked -0.42 and +0.42; Classic (recessed) and High Contrast (outlined) draw Mix Presentation in the form label style, T.styleLabel, in chromeInk. The weight is regular in every theme.',
    usedIn: {'lib/widgets/topbar.dart': 1},
    useCount: 1,
  ),
  'EclipsaStudioMark': ComponentInfo(
    name: 'EclipsaStudioMark',
    declaredIn: 'lib/widgets/eclipsa_studio_mark.dart',
    summary:
        'The cube mark, drawn from its own geometry rather than shipped as an asset: the E and the S projected onto the two front walls of an isometric cube 58 units tall, each a 5x5 dot-matrix letter drawn in the plane of its wall, under a 5x5 field of unlit cells (#64636A, one fixed grey in every theme) on the top face. The E takes textPrimary and the S pink, the tokens the wordmark beside it draws "Eclipsa" and "Studio" in. Geometry never varies by theme. Drawn beside the wordmark in EclipsaStudioLockup at 82 px on the landing screen and 31 px in the top bar in both workspace modes. The Theme Gallery draws it at 31 and 58 px. scripts/gen_app_icon.py generates the platform app icons and the brand masters from the same geometry.',
    usedIn: {'lib/widgets/eclipsa_studio_lockup.dart': 1},
    useCount: 1,
  ),
  'EclipsaStudioWordmark': ComponentInfo(
    name: 'EclipsaStudioWordmark',
    declaredIn: 'lib/widgets/eclipsa_studio_wordmark.dart',
    summary:
        'The "Eclipsa Studio" wordmark with its release-stage label, in the top bar and on the landing screen. One drawing in every theme: Inter at weight 600 with -2% tracking, "Eclipsa" in textPrimary and "Studio" in pink, the tokens the cube beside it uses for its E and S.',
    usedIn: {'lib/widgets/eclipsa_studio_lockup.dart': 1},
    useCount: 1,
  ),
  'EclipsaStudioLockup': ComponentInfo(
    name: 'EclipsaStudioLockup',
    declaredIn: 'lib/widgets/eclipsa_studio_lockup.dart',
    summary:
        'The mark beside the wordmark, spaced as the brand lockup in app/design/brand is: the mark\'s box is the type size over 0.515, the gap is 20/58 of that box measured from the cube\'s silhouette, and the wordmark\'s cap-height band is centred on the silhouette, with the baseline and cap height taken from Inter, the wordmark\'s face in every theme. On the landing screen at 42 px of type (an 82 px mark) and in the top bar at fontTitle (31 px). The wordmark keeps its BETA label, the public-beta label since 0.28.0.',
    usedIn: {
      'lib/widgets/topbar.dart': 1,
      'lib/workspace/landing_screen.dart': 1,
    },
    useCount: 2,
  ),
  'EclipsaAudioSymbol': ComponentInfo(
    name: 'EclipsaAudioSymbol',
    declaredIn: 'lib/widgets/eclipsa_audio_lockup.dart',
    summary:
        'The Eclipsa Audio symbol (the format\'s consumer brand, not the app\'s), drawn from its geometry rather than shipped as an asset: two mirrored halves, each an outer shape and a tall inner shape with their overlap filled in the core colour, as cubic Bézier curves fitted to the brand\'s lockup artwork. Colours are the brand\'s fixed greys (EclipsaAudioPalette), in the positive colourway over a light ground and the reverse over a dark one, never the theme\'s tokens. In the Theme Gallery at 24 and 48 px.',
    usedIn: {},
    useCount: 0,
  ),
  'EclipsaAudioLockup': ComponentInfo(
    name: 'EclipsaAudioLockup',
    declaredIn: 'lib/widgets/eclipsa_audio_lockup.dart',
    summary:
        'The horizontal greyscale Eclipsa Audio lockup: the symbol beside the wordmark "Eclipsa Audio" in Google Sans at weight 400, the wordmark drawn from twelve glyph outlines (eclipsa_audio_wordmark_data.dart, generated by scripts/gen_eclipsa_audio_wordmark.py) placed where the brand\'s lockup has them, cap height 190/324 of the symbol\'s height. Positive or reverse colourway by the ground\'s luminance. On the landing screen at 32 px under the app\'s own lockup, after the caption "Authoring for", and in the Theme Gallery.',
    usedIn: {'lib/workspace/landing_screen.dart': 1},
    useCount: 1,
  ),
  'VideoLane': ComponentInfo(
    name: 'VideoLane',
    declaredIn: 'lib/video/video_track.dart',
    summary:
        'The video\'s block on the timeline: the bar, the scrim past its end and the metadata chip clamped into view, in a 52 px row. Four drawings by ChromeStyle, each a 40 px lane: Classic and High Contrast draw a videoInk-tinted bar (a 0.5 px border at 25% in Classic, a 2 px border at full strength in High Contrast) with the chip at the top right; Dark\'s purpleDim lane in a borderStrong border with 15 guide lines and the chip at the bottom right; Light\'s light chrome lane under a dark gradient with an outlined chip at the bottom right. VideoTrack binds the transport and viewport to it.',
    usedIn: {},
    useCount: 0,
  ),
  'TrackPanel': ComponentInfo(
    name: 'TrackPanel',
    declaredIn: 'lib/widgets/track_lanes.dart',
    summary:
        'One track\'s controls panel in the sidebar column left of the lanes: the ground, the inset that separates it from the next panel, and the padding its controls lay out in. Two drawings by ChromeStyle: Classic, High Contrast and Dark fill nothing and draw one border line along the bottom (0.5 px, and High Contrast\'s borderWidth of 2), so the column reads as a list of rows; Light draws a bgSurface card at T.radius with no border, inset 4 px on every edge, over the bgBase strip trackPanelStripColor paints down the whole sidebar. The inset comes out of the panel\'s width and padding, so the column\'s width and the controls\' box do not move. _AudioTrack and VideoTrack both draw through it.',
    usedIn: {
      'lib/video/video_track.dart': 1,
      'lib/views/elements_view.dart': 1,
    },
    useCount: 2,
  ),
  'ChannelLabelCell': ComponentInfo(
    name: 'ChannelLabelCell',
    declaredIn: 'lib/widgets/track_lanes.dart',
    summary:
        'One channel\'s label in the gutter beside its lane, and beside it in the same file the block decoration, lane fill and lane spacing of an element\'s lanes and the TrackInfoChip at the block\'s end. Four drawings by ChromeStyle: Classic and High Contrast draw a bare fontSmall label (textSecondary in Classic, textPrimary in High Contrast) and an element-coloured block; Dark\'s 34 px bgDeep cell with a white label, bgSurface lanes divided by 1 px border lines; Light\'s bgControls chip in a borderLight border at radius 4 with a chromeTabOn label, bgControls lanes divided by 1 px borderLight lines. The Elements view composes them around MultiChannelWaveform.',
    usedIn: {'lib/views/elements_view.dart': 1},
    useCount: 1,
  ),
  'TrackInfoChip': ComponentInfo(
    name: 'TrackInfoChip',
    declaredIn: 'lib/widgets/track_lanes.dart',
    summary:
        'The compact format chip at the visible end of an element\'s block, truncating when narrow: fontMeter in the element\'s colour at 70% on bgDeep at 70% in Classic, the element\'s colour on bgBase in High Contrast, videoInk on bgBase at 92% in Dark, chromeTabOn with no ground in Light.',
    usedIn: {'lib/views/elements_view.dart': 1},
    useCount: 1,
  ),
  'TimeRulerStrip': ComponentInfo(
    name: 'TimeRulerStrip',
    declaredIn: 'lib/widgets/time_ruler.dart',
    summary:
        'The time ruler\'s strip: 32 px tall in every theme, against the 30 both concept frames draw, on a ground per ChromeStyle (bgSurface in Classic, bgBase in High Contrast, Dark and Light) with TimeRulerPainter across it, which draws the ticks in rulerTick, the labels in rulerLabel at fontBody and the playhead\'s head in playhead; PlayheadPainter draws the line down the tracks. The Elements view hosts the painters inside its own gesture handling. Classic draws a triangle head on a 1.5 px line; High Contrast takes Light\'s pentagon head on a 2 px playhead line drawn over a 4 px bgDeep casing.',
    usedIn: {},
    useCount: 0,
  ),
  'SoloMuteButton': ComponentInfo(
    name: 'SoloMuteButton',
    declaredIn: 'lib/widgets/solo_mute_button.dart',
    summary:
        'The S / M monitoring toggle on the elements view track panel, the mix view channel strip, the renderer view playback cards and the panel that opens over an output meter label in the Monitoring panel. Four drawings by ChromeStyle: Dark\'s bgControls face in a borderStrong rim, filled and rimmed with the active colour at 30% and 60% when engaged; Light\'s plain bgControls face with a chromeTabOn label when off and, when on, a border rim over bgElevated with the active colour filling it one pixel inside under an accentFg label; Classic\'s recessedWell, the transport buttons\' well, lit with the active colour at 30% when on; High Contrast\'s 2 px borderStrong outline when off and a solid fill in the active colour with an accentFg label when on. Solo is meterYellow and mute is meterRed in every style. 20 px at fontCaption in every theme, against the 24 px and Roboto 16 the frame draws.',
    usedIn: {
      'lib/views/elements_view.dart': 2,
      'lib/views/mix_view.dart': 2,
      'lib/views/output_meter.dart': 2,
      'lib/views/renderer_view.dart': 2,
    },
    useCount: 8,
  ),
  'StatusbarStrip': ComponentInfo(
    name: 'StatusbarStrip',
    declaredIn: 'lib/widgets/statusbar.dart',
    summary:
        'The status bar\'s ground and row: a ChromeSlice.statusbar surface with its items laid out horizontally inside a 24 px inset. Four drawings by ChromeStyle, each a 28 px bar with its items 24 px apart: a vertical gradient with two inset lines in Dark, the light chrome fill under a top border in Light, and statusbarBg under a 1 px chromeRim top edge in Classic and High Contrast. The text is fontBody in every style, in textMuted in Dark and chromeInk in the others.',
    usedIn: {'lib/video/video_popout_chrome.dart': 1},
    useCount: 1,
  ),
  'Statusbar': ComponentInfo(
    name: 'Statusbar',
    declaredIn: 'lib/widgets/statusbar.dart',
    summary:
        'Device, rate, buffer and engine load, bound to the app\'s providers and laid out on a StatusbarStrip. Names the active theme at its right-hand end.',
    usedIn: {'lib/widgets/app_shell.dart': 1},
    useCount: 1,
  ),
};
