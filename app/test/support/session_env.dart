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

// The two stand-ins a headless session test needs: the app-support
// directory (a platform channel in production) and the recent-session
// list (disk IO that outlives the call which started it).

import 'package:eclipsa_studio/session/session_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Routes the app-support directory to [root] so preference and
/// recent-list writes do real IO without a platform channel.
class FakePathProvider extends PathProviderPlatform {
  FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// [RecentSessionsNotifier] without the disk read. The real one refreshes
/// from `recent_sessions.json` after every load and save, and that read
/// outlives the call that started it — disposing a test's container under
/// it trips Riverpod's disposed-Ref assert.
class StubRecentSessions extends RecentSessionsNotifier {
  @override
  List<String> build() => const [];

  @override
  Future<void> refresh() async {}
}
