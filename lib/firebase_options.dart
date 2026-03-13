// Firebase configuration for Cruise Passenger app (com.cruise_app)
// Shared project: cruise-af9f1 (same as Dispatch Admin)
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAdwPUqsI8UuaEQEXw6aaNz7umWeGdWjjg',
    appId: '1:56054738352:web:175c4c0bf0377c59c1ba75',
    messagingSenderId: '56054738352',
    projectId: 'cruise-af9f1',
    authDomain: 'cruise-af9f1.firebaseapp.com',
    storageBucket: 'cruise-af9f1.firebasestorage.app',
    measurementId: 'G-E9KRTB7VPR',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA17wn7sSLxa7WInC8Z8FCA-Pjkb-a2eIw',
    appId: '1:56054738352:android:1868f64d184d1e63c1ba75',
    messagingSenderId: '56054738352',
    projectId: 'cruise-af9f1',
    storageBucket: 'cruise-af9f1.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBW_EyQYZUWbWzD6CAvxo9Btowb7bxALCU',
    appId: '1:56054738352:ios:7678cdaaa6ddc913c1ba75',
    messagingSenderId: '56054738352',
    projectId: 'cruise-af9f1',
    storageBucket: 'cruise-af9f1.firebasestorage.app',
    iosBundleId: 'com.cruiseinride.app',
  );
}
