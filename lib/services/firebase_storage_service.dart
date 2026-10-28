import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'firebase_auth_recovery.dart';

/// Handles Firebase Storage uploads for permanent profile photo storage.
/// URLs returned are permanent https://firebasestorage.googleapis.com/... links
/// that work across devices and survive server restarts.
class FirebaseStorageService {
  static final _storage = FirebaseStorage.instance;
  static final _firestore = FirebaseFirestore.instance;

  /// Ensure anonymous Firebase auth is active (required for Storage writes).
  static Future<void> _ensureAuth() async {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuthRecovery.ensureSignedIn();
    }
  }

  /// Upload a profile photo and return its permanent download URL.
  /// Uses role-specific paths so rider and driver photos never collide.
  /// Path: photos/{role}s/{userId}/profile.jpg (riders/123, drivers/456, etc.)
  static Future<String> uploadProfilePhoto(
      String filePath, int userId, String role) async {
    await _ensureAuth();
    final storagePath = 'photos/${role}s/$userId/profile.jpg';
    final ref = _storage.ref(storagePath);
    await ref.putFile(
      File(filePath),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return ref.getDownloadURL();
  }

  /// Update photoUrl in Firestore drivers/clients collection so Dispatch
  /// shows the new photo immediately.
  static Future<void> updateFirestorePhotoUrl(
    int userId,
    String photoUrl,
    String role,
  ) async {
    final collection = role == 'driver' ? 'drivers' : 'clients';
    try {
      final snap = await _firestore
          .collection(collection)
          .where('sqliteId', isEqualTo: userId)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        await snap.docs.first.reference.update({'photoUrl': photoUrl});
      }
      // Also save to 'users' collection (keyed by sqliteId) for cross-device sync
      await _firestore.collection('users').doc('sql_$userId').set({
        'photoUrl': photoUrl,
        'photoUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[FirebaseStorageService] updateFirestorePhotoUrl error: $e');
    }
  }

  /// Fetch the stored photo URL from Firestore users collection.
  /// Returns null if not found or on error.
  static Future<String?> fetchPhotoUrl(int userId) async {
    try {
      final doc = await _firestore.collection('users').doc('sql_$userId').get();
      final url = doc.data()?['photoUrl'] as String?;
      return (url != null && url.isNotEmpty) ? url : null;
    } catch (_) {
      return null;
    }
  }

  /// Migrate photo from Firebase Auth to Firestore users collection.
  /// Call once after login for existing users who have Auth photoURL
  /// but no Firestore record yet.
  static Future<void> syncAuthPhotoToFirestore(int userId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final authPhotoUrl = user.photoURL;
      if (authPhotoUrl == null || authPhotoUrl.isEmpty) return;

      // Check if Firestore already has it
      final doc = await _firestore.collection('users').doc('sql_$userId').get();
      final firestoreUrl = doc.data()?['photoUrl'] as String?;

      // Only sync if Firestore is missing it
      if (firestoreUrl == null || firestoreUrl.isEmpty) {
        await _firestore.collection('users').doc('sql_$userId').set({
          'photoUrl': authPhotoUrl,
          'photoUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        debugPrint('[FirebaseStorageService] Synced Auth photo to Firestore');
      }
    } catch (e) {
      debugPrint('[FirebaseStorageService] syncAuthPhotoToFirestore error: $e');
    }
  }
}
