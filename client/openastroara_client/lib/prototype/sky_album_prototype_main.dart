// PROTOTYPE — throwaway. Sky Album UI variants (#1500). Not wired into the app.
// Run: flutter run -d macos -t lib/prototype/sky_album_prototype_main.dart
import 'package:flutter/material.dart';

import '../theme/ara_theme.dart';
import 'sky_album_prototype.dart';

void main() => runApp(MaterialApp(
      theme: araTheme,
      debugShowCheckedModeBanner: false,
      home: const SkyAlbumPrototype(),
    ));
