package com.aakifosmani.overload

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity rather than FlutterActivity: Health Connect asks for
// permissions through the AndroidX activity-result APIs, which need a
// FragmentActivity host. Nothing else in the app depends on the difference.
class MainActivity : FlutterFragmentActivity()
