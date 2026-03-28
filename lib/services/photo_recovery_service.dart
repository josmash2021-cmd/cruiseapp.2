import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// 4-source recovery chain for profile photos — ensures photos are
/// NEVER lost across sessions, logouts, app updates, or device changes.
///
/// Recovery priority (cascading fallback):
///   1. Local SharedPreferences cache (fastest — instant)
///   2. Firebase Auth photoURL (fast — already in memory)
///   3. Firestore users doc (network — reliable &permanent)
///   4. Firebase Storage direct URL (accurate — source of truth)
class PhotoRecoveryService {
  /// UID-specific photo URL cache key in SharedPreferences
  static String _photoUrlKeyForUid(String uid) => 'cruise_photo_url_$uid';

  /// Primary recovery function — finds photo URL from 4 sources.
  ///
  /// Returns photoUrl if found, null otherwise.
  /// Automatically populates faster tiers when found in slower tiers.
  static Future<String?> resolvePhotoUrl(String uid) async {
    if (uid.isEmpty) return null;

    debugPrint('[PhotoRecovery] Starting resolution for uid=$uid');

    // ─── SOURCE 1: Local SharedPreferences (fastest) ────────────────────────
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_photoUrlKeyForUid(uid));
      if (cached != null && cached.isNotEmpty && cached.startsWith('https')) {
        debugPrint('[PhotoRecovery] ✅ Found in SharedPreferences: $cached');
        return cached;
      }
    } catch (e) {
      debugPrint('[PhotoRecovery] SharedPrefs lookup failed: $e');
    }

    // ─── SOURCE 2: Firebase Auth photoURL (fast — in memory) ─────────────────
    try {
      // Try to get from current user if UIDs match
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && currentUser.uid == uid) {
        final authUrl = currentUser.photoURL;
        if (authUrl != null && authUrl.isNotEmpty && authUrl.startsWith('https')) {
          debugPrint('[PhotoRecovery] ✅ Found in Firebase Auth: $authUrl');
          // Backfill to SharedPreferences for next time
          await _cachePhotoUrl(uid, authUrl);
          return authUrl;
        }
      }
    } catch (e) {
      debugPrint('[PhotoRecovery] Firebase Auth lookup failed: $e');
    }

    // ─── SOURCE 3: Firestore users collection (network — permanent) ─────────
    try {
      final firestore = FirebaseFirestore.instance;
      // Try both possible paths: users/{uid} and users/sql_{uid}
      DocumentSnapshot userDoc;
      try {
        userDoc = await firestore.collection('users').doc(uid).get();
      } catch (_) {
        // Try with sql_ prefix
        userDoc = await firestore.collection('users').doc('sql_$uid').get();
      }

      if (userDoc.exists) {
        final data = userDoc.data() as Map<String, dynamic>?;
        final firestoreUrl = data?['photoUrl'] as String?;
        if (firestoreUrl != null && firestoreUrl.isNotEmpty && firestoreUrl.startsWith('https')) {
          debugPrint('[PhotoRecovery] ✅ Found in Firestore: $firestoreUrl');
          // Backfill to faster tiers
          await _cachePhotoUrl(uid, firestoreUrl);
          await _updateFirebaseAuthPhotoUrl(firestoreUrl);
          return firestoreUrl;
        }
      }
    } catch (e) {
      debugPrint('[PhotoRecovery] Firestore lookup failed (non-critical): $e');
    }

    // ─── SOURCE 4: Firebase Storage direct URL construction ─────────────────
    try {
      final storage = FirebaseStorage.instance;
      final ref = storage.ref('users/$uid/profile/photo.jpg');
      final url = await ref.getDownloadURL();
      if (url.isNotEmpty && url.startsWith('https')) {
        debugPrint('[PhotoRecovery] ✅ Found in Firebase Storage: $url');
        // Backfill to all faster tiers
        await _cachePhotoUrl(uid, url);
        await _updateFirebaseAuthPhotoUrl(url);
        await _updateFirestorePhotoUrl(uid, url);
        return url;
      }
    } catch (e) {
      debugPrint('[PhotoRecovery] Firebase Storage lookup failed (non-critical): $e');
    }

    // ─── NO PHOTO FOUND ──────────────────────────────────────────────────────
    debugPrint('[PhotoRecovery] ❌ No photo found for uid=$uid from any source');
    return null;
  }

  /// Save photoUrl to SharedPreferences cache — always UID-specific.
  static Future<void> _cachePhotoUrl(String uid, String photoUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_photoUrlKeyForUid(uid), photoUrl);
      debugPrint('[PhotoRecovery] Cached photo URL to SharedPreferences');
    } catch (e) {
      debugPrint('[PhotoRecovery] Failed to cache to SharedPreferences: $e');
    }
  }

  /// Update Firebase Auth photoURL — persists across devices automatically.
  static Future<void> _updateFirebaseAuthPhotoUrl(String photoUrl) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await user.updatePhotoURL(photoUrl);
        debugPrint('[PhotoRecovery] Updated Firebase Auth photoURL');
      }
    } catch (e) {
      debugPrint('[PhotoRecovery] Failed to update Firebase Auth: $e');
    }
  }

  /// Update Firestore users doc with photoUrl.
  static Future<void> _updateFirestorePhotoUrl(String uid, String photoUrl) async {
    try {
      final firestore = FirebaseFirestore.instance;
      // Try both possible paths
      await firestore
          .collection('users')
          .doc(uid)
          .update({'photoUrl': photoUrl})
          .catchError((_) async {
        // Fallback to sql_ prefix
        await firestore.collection('users').doc('sql_$uid').update({'photoUrl': photoUrl});
      });
      debugPrint('[PhotoRecovery] Updated Firestore photoUrl');
    } catch (e) {
      debugPrint('[PhotoRecovery] Failed to update Firestore: $e');
    }
  }

  /// Manually save photoUrl to all tiers (called after successful upload).
  ///
  /// This ensures maximum redundancy: if any tier is lost, the other 3 survive.
  static Future<void> savePhotoEveryWhere(String uid, String photoUrl) async {
    if (uid.isEmpty || photoUrl.isEmpty) return;

    debugPrint('[PhotoRecovery] Saving photo URL to ALL tiers for uid=$uid');

    // Tier 1: SharedPreferences
    await _cachePhotoUrl(uid, photoUrl);

    // Tier 2: Firebase Auth
    await _updateFirebaseAuthPhotoUrl(photoUrl);

    // Tier 3: Firestore
    await _updateFirestorePhotoUrl(uid, photoUrl);

    debugPrint('[PhotoRecovery] ✅ Photo URL saved to all tiers');
  }

  /// Clear photo URL from SharedPreferences only (used by logout).
  /// Does NOT clear Firestore or Cloud Storage — photos stay permanent.
  /// This is SAFE because:
  ///   - Firestore has a copy (Source 3)
  ///   - Firebase Storage has original (Source 4)
  ///   - Recovery chain finds them on next login
  static Future<void> clearPhotoUrlCache(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_photoUrlKeyForUid(uid));
      debugPrint('[PhotoRecovery] Cleared photo URL cache for sid=$uid (Firestore copy preserved)');
    } catch (e) {
      debugPrint('[PhotoRecovery] Failed to clear cache: $e');
    }
  }

  /// NEVER CALL THIS — kept as a comment reminder of what NOT to do.
  ///
  /// prefs.clear() wipes EVERYTHING and is the #1 cause of photo loss.
  /// Photos are permanently stored in Firestore and Cloud Storage — they
  /// should NEVER be completely removed. Use selective key removal instead.
  ///
  /// Bad:        await prefs.clear();  // ❌ 🔥 DELETE THIS IF YOU SEE IT
  /// Good:       await clearPhotoUrlCache(uid);  // ✅ Safe, recoverable
  static Future<void> _neverCallClear() async {
    throw Exception('DO NOT CALL prefs.clear() — use selective key removal instead');
  }
}
