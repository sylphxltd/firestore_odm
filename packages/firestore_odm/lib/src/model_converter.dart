import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firestore_odm/src/firestore_odm.dart';

typedef JsonDeserializer<T> = T Function(Map<String, dynamic>);
typedef JsonSerializer<T> = Map<String, dynamic> Function(T);

// Removed ModelConverter class - now using FirestoreConverter system exclusively

/// Base interface for Firestore field converters
/// T: Dart type, F: Firestore type
abstract interface class FirestoreConverter<T, F> {
  T fromFirestore(F data);
  F toFirestore(T data);
}

/// Converter for DateTime <-> Timestamp
class DateTimeConverter implements FirestoreConverter<DateTime, dynamic> {
  const DateTimeConverter();
  
  @override
  DateTime fromFirestore(dynamic data) {
    if (data is Timestamp) {
      return data.toDate();
    } else if (data is String) {
      // Handle test environment where Timestamp might be serialized as String
      return DateTime.parse(data);
    } else if (data is int) {
      // Handle milliseconds since epoch
      return DateTime.fromMillisecondsSinceEpoch(data);
    } else {
      throw ArgumentError('Unsupported DateTime data type: ${data.runtimeType}');
    }
  }

  @override
  dynamic toFirestore(DateTime data) {
    // Check if this is the special server timestamp constant
    // If so, return it as-is so _replaceServerTimestamps can handle it later
    if (data == FirestoreODM.serverTimestamp) {
      return data;
    }
    return Timestamp.fromDate(data);
  }
}

/// Converter for Duration <-> int (microseconds)
class DurationConverter implements FirestoreConverter<Duration, dynamic> {
  const DurationConverter();
  
  @override
  Duration fromFirestore(dynamic data) {
    if (data is int) {
      return Duration(microseconds: data);
    } else if (data is double) {
      return Duration(microseconds: data.round());
    } else if (data is String) {
      // Handle test environment where int might be serialized as String
      final parsed = int.tryParse(data);
      if (parsed != null) {
        return Duration(microseconds: parsed);
      }
      throw ArgumentError('Invalid Duration string format: $data');
    } else {
      throw ArgumentError('Unsupported Duration data type: ${data.runtimeType}');
    }
  }

  @override
  dynamic toFirestore(Duration data) => data.inMicroseconds;
}

/// Converter for Uint8List <-> Blob
class BytesConverter implements FirestoreConverter<Uint8List, Blob> {
  const BytesConverter();
  
  @override
  Uint8List fromFirestore(Blob data) => data.bytes;

  @override
  Blob toFirestore(Uint8List data) => Blob(data);
}

/// Converter for GeoPoint (no conversion needed, but provides consistency)
class GeoPointConverter implements FirestoreConverter<GeoPoint, GeoPoint> {
  const GeoPointConverter();
  
  @override
  GeoPoint fromFirestore(GeoPoint data) => data;

  @override
  GeoPoint toFirestore(GeoPoint data) => data;
}

/// Converter for DocumentReference (no conversion needed, but provides consistency)
class DocumentReferenceConverter implements FirestoreConverter<DocumentReference, DocumentReference> {
  const DocumentReferenceConverter();
  
  @override
  DocumentReference fromFirestore(DocumentReference data) => data;

  @override
  DocumentReference toFirestore(DocumentReference data) => data;
}

/// Generic converter for Lists with element conversion
class ListConverter<T, F> implements FirestoreConverter<List<T>, List<F>> {
  final FirestoreConverter<T, F>? elementConverter;
  
  const ListConverter({this.elementConverter});

  @override
  List<T> fromFirestore(List<F> data) {
    if (elementConverter == null) {
      return data.cast<T>();
    }
    return data.map((item) => elementConverter!.fromFirestore(item)).toList();
  }

  @override
  List<F> toFirestore(List<T> data) {
    if (elementConverter == null) {
      return data.cast<F>();
    }
    return data.map((item) => elementConverter!.toFirestore(item)).toList();
  }
}

/// Generic converter for Maps with value conversion
class MapConverter<T, F> implements FirestoreConverter<Map<String, T>, Map<String, F>> {
  final FirestoreConverter<T, F>? valueConverter;
  
  const MapConverter({this.valueConverter});

  @override
  Map<String, T> fromFirestore(Map<String, F> data) {
    if (valueConverter == null) {
      return data.cast<String, T>();
    }
    return data.map((key, value) =>
        MapEntry(key, valueConverter!.fromFirestore(value)));
  }

  @override
  Map<String, F> toFirestore(Map<String, T> data) {
    if (valueConverter == null) {
      return data.cast<String, F>();
    }
    return data.map((key, value) =>
        MapEntry(key, valueConverter!.toFirestore(value)));
  }
}

/// Generic converter for custom objects using fromJson/toJson functions
class ObjectConverter<T> implements FirestoreConverter<T, Map<String, dynamic>> {
  final JsonDeserializer<T> fromJson;
  final JsonSerializer<T> toJson;
  
  const ObjectConverter({required this.fromJson, required this.toJson});

  @override
  T fromFirestore(Map<String, dynamic> data) => fromJson(data);

  @override
  Map<String, dynamic> toFirestore(T data) => toJson(data);
}

/// Converter for nullable types
class NullableConverter<T, F> implements FirestoreConverter<T?, F?> {
  final FirestoreConverter<T, F> innerConverter;
  
  const NullableConverter(this.innerConverter);

  @override
  T? fromFirestore(F? data) {
    if (data == null) return null;
    return innerConverter.fromFirestore(data);
  }

  @override
  F? toFirestore(T? data) {
    if (data == null) return null;
    return innerConverter.toFirestore(data);
  }
}


/// Predefined converter instances for common types
class FirestoreConverters {
  static const dateTime = DateTimeConverter();
  static const duration = DurationConverter();
  static const bytes = BytesConverter();
  static const geoPoint = GeoPointConverter();
  static const documentReference = DocumentReferenceConverter();
  
  /// Create a list converter with optional element converter
  static ListConverter<T, F> list<T, F>([FirestoreConverter<T, F>? elementConverter]) =>
      ListConverter<T, F>(elementConverter: elementConverter);
  
  /// Create a map converter with optional value converter
  static MapConverter<T, F> map<T, F>([FirestoreConverter<T, F>? valueConverter]) =>
      MapConverter<T, F>(valueConverter: valueConverter);
  
  /// Create an object converter using JsonDeserializer and JsonSerializer
  // static ObjectConverter<T> object<T>({
  //   required JsonDeserializer<T> fromJson,
  //   required JsonSerializer<T> toJson,
  // }) => ObjectConverter<T>(fromJson: fromJson, toJson: toJson);
  
  /// Create a nullable converter
  static NullableConverter<T, F> nullable<T, F>(FirestoreConverter<T, F> innerConverter) =>
      NullableConverter<T, F>(innerConverter);
}