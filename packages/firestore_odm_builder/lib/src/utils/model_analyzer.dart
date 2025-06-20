import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:source_gen/source_gen.dart';
import 'package:json_annotation/json_annotation.dart';
import 'type_analyzer.dart';

/// Firestore data type representation for Firestore ODM
/// Based on official Firestore supported data types
enum FirestoreType {
  // Primitive types
  string, // Text string
  integer, // 64-bit signed integer
  double, // 64-bit double precision floating-point
  boolean, // Boolean
  timestamp, // Date and time
  bytes, // Byte data
  geoPoint, // Geographical point
  reference, // Document reference
  // Complex types
  array, // Array
  map, // Map (embedded object)
  // Special values
  null_, // Null value
  // For custom objects that will be serialized as maps
  object,
}

/// Functional converter interface for type conversions
abstract class TypeConverter {
  String generateFromFirestore(String sourceExpression);
  String generateToFirestore(String sourceExpression);
}

/// Direct converter for primitive types (no conversion needed)
class DirectConverter implements TypeConverter {
  final String dartTypeName;
  
  const DirectConverter(this.dartTypeName);
  
  @override
  String generateFromFirestore(String sourceExpression) {
    return '$sourceExpression as $dartTypeName';
  }
  
  @override
  String generateToFirestore(String sourceExpression) {
    return sourceExpression;
  }
}

/// Converter using a specific converter class
class ConverterClassConverter implements TypeConverter {
  final String converterClassName;
  
  const ConverterClassConverter(this.converterClassName);
  
  @override
  String generateFromFirestore(String sourceExpression) {
    return 'const $converterClassName().fromFirestore($sourceExpression)';
  }
  
  @override
  String generateToFirestore(String sourceExpression) {
    return 'const $converterClassName().toFirestore($sourceExpression)';
  }
}

/// Converter for JSON serializable objects
class JsonConverter implements TypeConverter {
  final String typeName;
  
  const JsonConverter(this.typeName);
  
  @override
  String generateFromFirestore(String sourceExpression) {
    return '$typeName.fromJson($sourceExpression as Map<String, dynamic>)';
  }
  
  @override
  String generateToFirestore(String sourceExpression) {
    return '$sourceExpression.toJson()';
  }
}

/// Converter for generic types with element converters
class GenericConverter implements TypeConverter {
  final String typeName;
  final List<TypeConverter> elementConverters;
  
  const GenericConverter(this.typeName, this.elementConverters);
  
  @override
  String generateFromFirestore(String sourceExpression) {
    if (elementConverters.length == 1) {
      // Collection types (List, Set, IList, ISet)
      final elementConverter = elementConverters.first;
      if (elementConverter is DirectConverter) {
        // For primitive element types, use cast
        final elementTypeName = elementConverter.dartTypeName;
        if (typeName.startsWith('IList<') || typeName.startsWith('ISet<')) {
          // Immutable collections need proper conversion
          return '$typeName.fromJson($sourceExpression, (e) => e as $elementTypeName)';
        }
        return '($sourceExpression as List<dynamic>).cast<$elementTypeName>()';
      } else {
        // For complex element types, use map
        final converterFunction = '(e) => ${elementConverter.generateFromFirestore('e')}';
        return '$typeName.fromJson($sourceExpression, $converterFunction)';
      }
    } else if (elementConverters.length == 2) {
      // Map types (Map, IMap)
      final keyConverter = elementConverters[0];
      final valueConverter = elementConverters[1];
      
      if (keyConverter is DirectConverter && valueConverter is DirectConverter) {
        // For primitive key-value types, use cast
        final keyTypeName = keyConverter.dartTypeName;
        final valueTypeName = valueConverter.dartTypeName;
        // Special case for Map<String, dynamic> - no conversion needed
        if (keyTypeName == 'String' && valueTypeName == 'dynamic') {
          return '$sourceExpression as Map<String, dynamic>';
        }
        if (typeName.startsWith('IMap<')) {
          // Immutable maps need proper conversion
          return '$typeName.fromJson($sourceExpression, (k) => k as $keyTypeName, (v) => v as $valueTypeName)';
        }
        return '($sourceExpression as Map<String, dynamic>).cast<$keyTypeName, $valueTypeName>()';
      } else {
        // For complex types, use converters
        final keyConverterFunction = '(k) => ${keyConverter.generateFromFirestore('k')}';
        final valueConverterFunction = '(v) => ${valueConverter.generateFromFirestore('v')}';
        return '$typeName.fromJson($sourceExpression, $keyConverterFunction, $valueConverterFunction)';
      }
    }
    throw ArgumentError('Unsupported number of element converters: ${elementConverters.length}');
  }
  
  @override
  String generateToFirestore(String sourceExpression) {
    if (elementConverters.length == 1) {
      // Collection types
      final elementConverter = elementConverters.first;
      if (elementConverter is DirectConverter) {
        // For primitive element types, check if it's an immutable collection
        if (typeName.startsWith('IList<') || typeName.startsWith('ISet<')) {
          // Immutable collections need toJson conversion even for primitives
          return '$sourceExpression.toJson((e) => e)';
        }
        // Regular collections with primitives need no conversion
        return sourceExpression;
      } else {
        // For complex element types, use map
        final converterFunction = '(e) => ${elementConverter.generateToFirestore('e')}';
        return '$sourceExpression.toJson($converterFunction)';
      }
    } else if (elementConverters.length == 2) {
      // Map types
      final keyConverter = elementConverters[0];
      final valueConverter = elementConverters[1];
      
      if (keyConverter is DirectConverter && valueConverter is DirectConverter) {
        // For primitive key-value types, check if it's an immutable map
        if (typeName.startsWith('IMap<')) {
          // Immutable maps need toJson conversion even for primitives
          return '$sourceExpression.toJson((k) => k, (v) => v)';
        }
        // Regular maps with primitives need no conversion
        return sourceExpression;
      } else {
        // For complex types, use converters
        final keyConverterFunction = '(k) => ${keyConverter.generateToFirestore('k')}';
        final valueConverterFunction = '(v) => ${valueConverter.generateToFirestore('v')}';
        return '$sourceExpression.toJson($keyConverterFunction, $valueConverterFunction)';
      }
    }
    throw ArgumentError('Unsupported number of element converters: ${elementConverters.length}');
  }
}

/// Converter for custom JsonConverter annotations
class AnnotationConverter implements TypeConverter {
  final String converterClassName;
  
  const AnnotationConverter(this.converterClassName);
  
  @override
  String generateFromFirestore(String sourceExpression) {
    return 'const $converterClassName().fromJson($sourceExpression)';
  }
  
  @override
  String generateToFirestore(String sourceExpression) {
    return 'const $converterClassName().toJson($sourceExpression)';
  }
}

/// Nullable wrapper converter
class NullableConverter implements TypeConverter {
  final TypeConverter innerConverter;
  
  const NullableConverter(this.innerConverter);
  
  @override
  String generateFromFirestore(String sourceExpression) {
    final innerExpression = innerConverter.generateFromFirestore(sourceExpression);
    // Avoid double null checks if the inner converter already handles nulls
    if (innerExpression.contains('== null ? null :')) {
      return innerExpression;
    }
    return '$sourceExpression == null ? null : $innerExpression';
  }
  
  @override
  String generateToFirestore(String sourceExpression) {
    final innerExpression = innerConverter.generateToFirestore('$sourceExpression!');
    // Avoid double null checks if the inner converter already handles nulls
    if (innerExpression.contains('== null ? null :')) {
      return innerExpression;
    }
    return '$sourceExpression == null ? null : $innerExpression';
  }
}

/// Information about a field in a model
class FieldInfo {
  final String parameterName;
  final String jsonFieldName;
  final DartType dartType;
  final bool isDocumentId;
  final bool isNullable;
  final bool isOptional;
  final TypeAnalysisResult typeAnalysis;

  const FieldInfo({
    required this.parameterName,
    required this.jsonFieldName,
    required this.dartType,
    required this.isDocumentId,
    required this.isNullable,
    required this.isOptional,
    required this.typeAnalysis,
  });

  /// Get Firestore type from type analysis
  FirestoreType get firestoreType => typeAnalysis.firestoreType;
  
  /// Get converter from type analysis
  TypeConverter get converter => typeAnalysis.converter;

  /// Generate conversion from Firestore
  String generateFromFirestore(String sourceExpression) {
    return typeAnalysis.converter.generateFromFirestore(sourceExpression);
  }

  /// Generate conversion to Firestore
  String generateToFirestore(String sourceExpression) {
    return typeAnalysis.converter.generateToFirestore(sourceExpression);
  }

  @override
  String toString() =>
      'FieldInfo(param: $parameterName, json: $jsonFieldName, type: $dartType, firestoreType: $firestoreType, isDocId: $isDocumentId)';
}

/// Complete analysis of a model class
class ModelAnalysis {
  final String className;
  final String? documentIdFieldName;
  final Map<String, FieldInfo> fields;
  final List<FieldInfo> updateableFields;
  final bool hasManualSerialization;
  final TypeAnalysisResult classTypeAnalysis;

  const ModelAnalysis({
    required this.className,
    required this.documentIdFieldName,
    required this.fields,
    required this.updateableFields,
    required this.hasManualSerialization,
    required this.classTypeAnalysis,
  });

  /// Get field by parameter name
  FieldInfo? getFieldByParam(String paramName) => fields[paramName];

  /// Get document ID field info
  FieldInfo? get documentIdField =>
      documentIdFieldName != null ? fields[documentIdFieldName] : null;

  @override
  String toString() =>
      'ModelAnalysis(class: $className, docIdField: $documentIdFieldName, fields: ${fields.length}, hasManualSerialization: $hasManualSerialization)';
}

/// Type analysis result with caching
class TypeAnalysisResult {
  final FirestoreType firestoreType;
  final TypeConverter converter;
  final bool hasJsonSupport;
  final bool hasGenericJsonSupport;

  const TypeAnalysisResult({
    required this.firestoreType,
    required this.converter,
    required this.hasJsonSupport,
    required this.hasGenericJsonSupport,
  });
}

/// Registry for caching type analysis results
class TypeRegistry {
  final Map<String, TypeAnalysisResult> _cache = {};
  final Map<String, ModelAnalysis> _modelCache = {};

  /// Get or analyze a type
  TypeAnalysisResult getOrAnalyzeType(DartType dartType, Element? element) {
    final typeKey = _getTypeKey(dartType, element);
    
    if (_cache.containsKey(typeKey)) {
      return _cache[typeKey]!;
    }

    final result = _analyzeType(dartType, element);
    _cache[typeKey] = result;
    return result;
  }

  /// Get or analyze a model
  ModelAnalysis? getOrAnalyzeModel(ClassElement classElement) {
    final className = classElement.name;
    
    if (_modelCache.containsKey(className)) {
      return _modelCache[className];
    }

    final result = ModelAnalyzer._analyzeModelInternal(classElement, this);
    if (result != null) {
      _modelCache[className] = result;
    }
    return result;
  }

  /// Generate a unique key for a type including element annotations
  String _getTypeKey(DartType dartType, Element? element) {
    final typeString = dartType.getDisplayString(withNullability: true);
    
    // Include custom JsonConverter annotations in the key to avoid cache conflicts
    if (element != null) {
      final customConverter = _findCustomJsonConverter(element);
      if (customConverter != null) {
        return '$typeString@$customConverter';
      }
    }
    
    return typeString;
  }

  /// Analyze a type and return its analysis result
  TypeAnalysisResult _analyzeType(DartType dartType, Element? element) {
    final firestoreType = ModelAnalyzer._determineFirestoreType(dartType, element);
    final converter = _createConverter(dartType, element, firestoreType);
    final hasJsonSupport = ModelAnalyzer._hasStandardJsonSupport(dartType);
    final hasGenericJsonSupport = ModelAnalyzer._hasGenericJsonSupport(dartType);

    return TypeAnalysisResult(
      firestoreType: firestoreType,
      converter: converter,
      hasJsonSupport: hasJsonSupport,
      hasGenericJsonSupport: hasGenericJsonSupport,
    );
  }

  /// Create appropriate converter for a type
  TypeConverter _createConverter(DartType dartType, Element? element, FirestoreType firestoreType) {
    final typeName = dartType.getDisplayString(withNullability: false);
    final isNullable = TypeAnalyzer.isNullableType(dartType);

    TypeConverter baseConverter;

    // Check for custom JsonConverter annotations first (like @ListLengthConverter())
    if (element != null) {
      // Look for any annotation that implements JsonConverter
      final customConverter = _findCustomJsonConverter(element);
      if (customConverter != null) {
        baseConverter = AnnotationConverter(customConverter);
      } else {
        // Check for standard @JsonConverter annotation
        final jsonConverter = ModelAnalyzer._jsonConverterChecker.firstAnnotationOf(element);
        if (jsonConverter != null) {
          final converterType = jsonConverter.type;
          if (converterType != null && converterType is InterfaceType) {
            final converterClassName = converterType.element3.name3!;
            baseConverter = AnnotationConverter(converterClassName);
          } else {
            baseConverter = _createDefaultConverter(dartType, firestoreType);
          }
        } else {
          baseConverter = _createDefaultConverter(dartType, firestoreType);
        }
      }
    } else {
      baseConverter = _createDefaultConverter(dartType, firestoreType);
    }

    // Wrap with nullable converter if needed
    if (isNullable) {
      return NullableConverter(baseConverter);
    }

    return baseConverter;
  }

  /// Find custom JsonConverter annotation (like @ListLengthConverter())
  String? _findCustomJsonConverter(Element element) {
    for (final annotation in element.metadata) {
      final annotationType = annotation.computeConstantValue()?.type;
      if (annotationType is InterfaceType) {
        final classElement = annotationType.element;
        
        // Check if this class implements JsonConverter interface
        if (_implementsJsonConverter(classElement)) {
          return classElement.name;
        }
      }
    }
    return null;
  }

  /// Check if a class implements JsonConverter interface
  bool _implementsJsonConverter(Element classElement) {
    if (classElement is! ClassElement) return false;
    
    // Check all interfaces and superclasses
    for (final interface in classElement.allSupertypes) {
      final interfaceName = interface.element.name;
      if (interfaceName == 'JsonConverter') {
        return true;
      }
    }
    return false;
  }

  /// Create default converter based on type and firestore type
  TypeConverter _createDefaultConverter(DartType dartType, FirestoreType firestoreType) {
    final typeName = dartType.getDisplayString(withNullability: false);
// Handle dynamic type specially
    if (typeName == 'dynamic') {
      return DirectConverter(typeName);
    }

    switch (firestoreType) {
      case FirestoreType.string:
      case FirestoreType.boolean:
      case FirestoreType.double:
        return DirectConverter(typeName);

      case FirestoreType.integer:
        if (typeName == 'Duration') {
          return ConverterClassConverter('DurationConverter');
        }
        return DirectConverter(typeName);

      case FirestoreType.timestamp:
        return ConverterClassConverter('DateTimeConverter');

      case FirestoreType.bytes:
        return ConverterClassConverter('BytesConverter');

      case FirestoreType.geoPoint:
      case FirestoreType.reference:
        return DirectConverter(typeName);

      case FirestoreType.array:
        return _createCollectionConverter(dartType);

      case FirestoreType.map:
        return _createMapConverter(dartType);

      case FirestoreType.object:
        if (ModelAnalyzer._hasGenericJsonSupport(dartType)) {
          return _createGenericConverter(dartType);
        } else if (ModelAnalyzer._hasStandardJsonSupport(dartType)) {
          return JsonConverter(typeName);
        } else {
          // Custom object converter
          return JsonConverter(typeName);
        }

      case FirestoreType.null_:
        return DirectConverter(typeName);
    }
  }

  /// Create converter for collection types
  TypeConverter _createCollectionConverter(DartType dartType) {
    final typeName = dartType.getDisplayString(withNullability: false);
    
    if (dartType is InterfaceType && dartType.typeArguments.isNotEmpty) {
      final elementType = dartType.typeArguments.first;
      final elementConverter = getOrAnalyzeType(elementType, null).converter;
      return GenericConverter(typeName, [elementConverter]);
    }

    return DirectConverter(typeName);
  }

  /// Create converter for map types
  TypeConverter _createMapConverter(DartType dartType) {
    final typeName = dartType.getDisplayString(withNullability: false);
    
    if (dartType is InterfaceType && dartType.typeArguments.length >= 2) {
      final keyType = dartType.typeArguments[0];
      final valueType = dartType.typeArguments[1];
      final keyConverter = getOrAnalyzeType(keyType, null).converter;
      final valueConverter = getOrAnalyzeType(valueType, null).converter;
      return GenericConverter(typeName, [keyConverter, valueConverter]);
    }

    return DirectConverter(typeName);
  }

  /// Create converter for generic types with custom JSON support
  TypeConverter _createGenericConverter(DartType dartType) {
    final typeName = dartType.getDisplayString(withNullability: false);
    
    if (dartType is InterfaceType) {
      if (dartType.typeArguments.length == 1) {
        // Collection-like
        final elementType = dartType.typeArguments.first;
        final elementConverter = getOrAnalyzeType(elementType, null).converter;
        return GenericConverter(typeName, [elementConverter]);
      } else if (dartType.typeArguments.length >= 2) {
        // Map-like
        final keyType = dartType.typeArguments[0];
        final valueType = dartType.typeArguments[1];
        final keyConverter = getOrAnalyzeType(keyType, null).converter;
        final valueConverter = getOrAnalyzeType(valueType, null).converter;
        return GenericConverter(typeName, [keyConverter, valueConverter]);
      }
    }

    return JsonConverter(typeName);
  }
}

/// Analyzer for complete model structure including JSON field mapping
class ModelAnalyzer {
  static final TypeChecker _jsonKeyChecker = TypeChecker.fromRuntime(JsonKey);
  static final TypeChecker _jsonConverterChecker = TypeChecker.fromRuntime(
    JsonConverter,
  );

  /// Analyze a complete model class and return structured information
  static ModelAnalysis? analyzeModel(ClassElement classElement) {
    final registry = TypeRegistry();
    return registry.getOrAnalyzeModel(classElement);
  }

  /// Internal method for analyzing a model with a given registry
  static ModelAnalysis? _analyzeModelInternal(ClassElement classElement, TypeRegistry registry) {
    try {
      // Get all fields from the class and its supertypes (excluding Object)
      final fields = _getConstructorParameters(classElement);

      if (fields.isEmpty) {
        return null;
      }

      // Analyze all fields
      final Map<String, FieldInfo> fieldsMap = {};

      for (final (fieldName, fieldType, element) in fields) {
        final fieldInfo = _analyzeFieldFromAccessor(
          fieldName,
          fieldType,
          element,
          registry,
        );
        fieldsMap[fieldName] = fieldInfo;
      }

      // Find document ID field using logic
      final documentIdFieldName = _getDocumentIdFieldFromAccessors(fields);

      // Mark document ID field
      if (documentIdFieldName != null &&
          fieldsMap.containsKey(documentIdFieldName)) {
        final existingField = fieldsMap[documentIdFieldName]!;
        fieldsMap[documentIdFieldName] = FieldInfo(
          parameterName: existingField.parameterName,
          jsonFieldName: existingField.jsonFieldName,
          dartType: existingField.dartType,
          isDocumentId: true,
          isNullable: existingField.isNullable,
          isOptional: existingField.isOptional,
          typeAnalysis: existingField.typeAnalysis,
        );
      }

      // Get updateable fields (non-document-ID fields)
      final updateableFields = fieldsMap.values
          .where((field) => !field.isDocumentId)
          .toList();

      // Get class type analysis
      final classTypeAnalysis = registry.getOrAnalyzeType(classElement.thisType, classElement);

      return ModelAnalysis(
        className: classElement.name,
        documentIdFieldName: documentIdFieldName,
        fields: fieldsMap,
        updateableFields: updateableFields,
        hasManualSerialization: classTypeAnalysis.hasJsonSupport,
        classTypeAnalysis: classTypeAnalysis,
      );
    } catch (e) {
      return null;
    }
  }

  /// Analyze a model and all its nested types recursively
  static Map<String, ModelAnalysis> analyzeModelWithNestedTypes(
    ClassElement rootClassElement,
  ) {
    final registry = TypeRegistry();
    final Map<String, ModelAnalysis> allAnalyses = {};
    final Set<String> processedTypes = {};

    _analyzeModelRecursively(rootClassElement, allAnalyses, processedTypes, registry);

    return allAnalyses;
  }

  /// Recursively analyze a model and discover all nested custom types
  static void _analyzeModelRecursively(
    ClassElement classElement,
    Map<String, ModelAnalysis> allAnalyses,
    Set<String> processedTypes,
    TypeRegistry registry,
  ) {
    final typeName = classElement.name;

    // Skip if already processed
    if (processedTypes.contains(typeName)) {
      return;
    }
    processedTypes.add(typeName);

    // Analyze the current model
    final analysis = registry.getOrAnalyzeModel(classElement);
    if (analysis != null) {
      allAnalyses[typeName] = analysis;

      // Process nested types in all fields
      for (final field in analysis.fields.values) {
        _processFieldTypeForNestedModels(
          field.dartType,
          allAnalyses,
          processedTypes,
          registry,
        );
      }
    }
  }

  /// Process a field type to discover nested custom model types
  static void _processFieldTypeForNestedModels(
    DartType fieldType,
    Map<String, ModelAnalysis> allAnalyses,
    Set<String> processedTypes,
    TypeRegistry registry,
  ) {
    // Handle nullable types
    final actualType = fieldType.nullabilitySuffix == NullabilitySuffix.question
        ? (fieldType as InterfaceType).element.thisType
        : fieldType;

    if (actualType is InterfaceType) {
      final element = actualType.element;

      if (TypeAnalyzer.isPrimitiveType(actualType)) {
        return; // Skip primitive types
      }

      if (element is ClassElement) {
        // If it's a custom class, analyze it recursively
        _analyzeModelRecursively(element, allAnalyses, processedTypes, registry);
      }

      // Handle generic types (List<T>, Map<K,V>)
      for (final typeArg in actualType.typeArguments) {
        _processFieldTypeForNestedModels(typeArg, allAnalyses, processedTypes, registry);
      }
    }
  }

  /// Get all fields from the class and its supertypes (excluding Object)
  static List<(String, DartType, Element)> _getConstructorParameters(
    ClassElement classElement,
  ) {
    // 搵 factory constructor
    var constructor = classElement.constructors
        .where((c) => c.isFactory && c.name.isEmpty)
        .firstOrNull;

    // 如果 factory constructor redirect 到另一個 constructor，追上去
    if (constructor != null && constructor.redirectedConstructor != null) {
      constructor = constructor.redirectedConstructor;
    }

    // 如果仲係冇，搵 default constructor
    constructor ??= classElement.constructors
        .where((c) => !c.isFactory && c.name.isEmpty)
        .firstOrNull;

    if (constructor == null) {
      throw Exception('No suitable constructor found for ${classElement.name}');
    }

    return _extractParameters(constructor);
  }

  static List<(String, DartType, Element)> _extractParameters(
    ConstructorElement constructor,
  ) {
    return constructor.parameters
        .where((p) => p.isNamed) // Only named parameters
        .where((p) {
          // Check JsonKey annotations
          final jsonKey = _jsonKeyChecker.firstAnnotationOf(p);
          if (jsonKey != null) {
            final jsonKeyConstantReader = ConstantReader(jsonKey);

            // Check includeFromJson
            bool includeFromJson = true;
            try {
              final includeFromJsonField = jsonKeyConstantReader.read(
                'includeFromJson',
              );
              if (!includeFromJsonField.isNull) {
                includeFromJson = includeFromJsonField.boolValue;
              }
            } catch (e) {
              // Field not present, use default value true
            }

            // Check includeToJson
            bool includeToJson = true;
            try {
              final includeToJsonField = jsonKeyConstantReader.read(
                'includeToJson',
              );
              if (!includeToJsonField.isNull) {
                includeToJson = includeToJsonField.boolValue;
              }
            } catch (e) {
              // Field not present, use default value true
            }

            return includeFromJson && includeToJson;
          }
          return true;
        })
        .map((p) => (p.name, p.type, p))
        .toList();
  }

  /// Analyze a field from accessor element
  static FieldInfo _analyzeFieldFromAccessor(
    String fieldName,
    DartType fieldType,
    Element element,
    TypeRegistry registry,
  ) {
    final isNullable = TypeAnalyzer.isNullableType(fieldType);
    final isOptional = isNullable;

    // Determine JSON field name
    String jsonFieldName = fieldName;

    // Check for @JsonKey annotation
    final jsonKey = _jsonKeyChecker.firstAnnotationOf(element);
    if (jsonKey != null) {
      final jsonKeyConstantReader = ConstantReader(jsonKey);
      final nameValue = jsonKeyConstantReader.read('name').stringValue;
      if (nameValue.isNotEmpty) {
        jsonFieldName = nameValue;
      }
    }

    // Get type analysis result from registry
    final typeResult = registry.getOrAnalyzeType(fieldType, element);

    return FieldInfo(
      parameterName: fieldName,
      jsonFieldName: jsonFieldName,
      dartType: fieldType,
      isDocumentId: false,
      isNullable: isNullable,
      isOptional: isOptional,
      typeAnalysis: typeResult,
    );
  }

  /// Determine the Firestore type for a Dart type
  /// Based on official Firestore supported data types, @JsonConverter annotations, and toJson/fromJson methods
  static FirestoreType _determineFirestoreType(
    DartType dartType,
    Element? element,
  ) {
    // First, check for @JsonConverter annotation
    if (element != null) {
      final jsonConverter = _jsonConverterChecker.firstAnnotationOf(element);
      if (jsonConverter != null) {
        // Get the JsonType from JsonConverter<DartType, JsonType>
        final converterType = jsonConverter.type;
        if (converterType != null && converterType is InterfaceType) {
          final typeArguments = converterType.typeArguments;
          if (typeArguments.length >= 2) {
            // Use the JsonType (second argument) to determine Firestore type
            return _processTypeToFirestoreType(typeArguments[1]);
          }
        }
      }
    }

    // If no @JsonConverter, check if this is a custom object type with toJson/fromJson
    if (dartType is InterfaceType) {
      final typeName = dartType.getDisplayString(withNullability: false);

      // Skip primitive and known types
      if (!TypeAnalyzer.isPrimitiveType(dartType) &&
          !_isKnownFirestoreType(typeName)) {
        // Analyze based on what toJson would return for common immutable collection types
        // IList/ISet -> toJson returns List -> array
        if (typeName.startsWith('IList<') || typeName.startsWith('ISet<')) {
          return FirestoreType.array;
        }
        // IMap -> toJson returns Map -> map
        else if (typeName.startsWith('IMap<')) {
          return FirestoreType.map;
        }
        // Other custom objects with toJson/fromJson -> object
        else {
          return FirestoreType.object;
        }
      }
    }

    // Process the original Dart type to determine Firestore type
    return _processTypeToFirestoreType(dartType);
  }

  /// Process a Dart type to determine its Firestore type
  static FirestoreType _processTypeToFirestoreType(DartType dartType) {
    // Handle nullable types by getting the underlying type
    final actualType = dartType.nullabilitySuffix == NullabilitySuffix.question
        ? (dartType as InterfaceType).element3.thisType
        : dartType;
    // Handle primitive types
    if (TypeAnalyzer.isStringType(actualType)) {
      return FirestoreType.string;
    }
    if (TypeAnalyzer.isIntType(actualType)) {
      return FirestoreType.integer;
    }
    if (TypeAnalyzer.isDoubleType(actualType)) {
      return FirestoreType.double;
    }
    if (TypeAnalyzer.isBoolType(actualType)) {
      return FirestoreType.boolean;
    }

    // Handle special types that convert to different Firestore types
    if (TypeAnalyzer.isDurationType(actualType)) {
      return FirestoreType
          .integer; // Duration converts to milliseconds (integer)
    }
    if (TypeAnalyzer.isDateTimeType(actualType)) {
      return FirestoreType
          .timestamp; // DateTime converts to Firestore Timestamp
    }

    if (TypeAnalyzer.isMapType(actualType)) {
      return FirestoreType.map;
    }
    
    // Handle collections
    if (TypeAnalyzer.isListType(actualType)) {
      return FirestoreType.array;
    }

    // For custom objects, return object type (will be serialized as map)
    return FirestoreType.object;
  }

  /// Find the document ID field from accessors
  static String? _getDocumentIdFieldFromAccessors(
    List<(String, DartType, Element)> fields,
  ) {
    // First pass: Look for explicit @DocumentIdField() annotation
    for (final (fieldName, _, element) in fields) {
      final documentIdAnnotation = TypeAnalyzer.documentIdChecker
          .firstAnnotationOf(element);
      if (documentIdAnnotation != null) {
        return fieldName;
      }
    }

    // Second pass: Look for a field named 'id' as default
    for (final (fieldName, fieldType, _) in fields) {
      if (fieldName == 'id' && TypeAnalyzer.isStringType(fieldType)) {
        return fieldName;
      }
    }

    return null;
  }

  /// Check if type supports standard JSON serialization
  static bool _hasStandardJsonSupport(DartType dartType) {
    if (dartType is! InterfaceType) {
      return false;
    }

    final classElement = dartType.element;
    if (classElement is! ClassElement) {
      return false;
    }

    // Check for fromJson constructor or static method (one parameter)
    final hasFromJson = _hasFromJsonMethod(classElement);

    // Check for toJson method (no parameters) in class hierarchy
    final hasToJson = _hasToJsonMethod(classElement);

    return hasFromJson && hasToJson;
  }

  /// Check if class or its hierarchy has fromJson method
  static bool _hasFromJsonMethod(ClassElement classElement) {
  // Get all classes in hierarchy (current + supertypes, excluding Object)
  final allClasses = [
    classElement,
    ...classElement.allSupertypes
        .where((type) => type.element.name != 'Object')
        .map((type) => type.element)
        .whereType<ClassElement>()
  ];

  // Check if any class has fromJson
  return allClasses.any((element) {
    final hasConstructor = element.constructors.any(
      (c) => c.name == 'fromJson' && c.parameters.length == 1,
    );
    
    final hasStaticMethod = element.methods.any(
      (m) => m.name == 'fromJson' && m.isStatic && m.parameters.length == 1,
    );
    
    return hasConstructor || hasStaticMethod;
  });
}
  /// Check if class or its hierarchy has toJson method
  static bool _hasToJsonMethod(ClassElement classElement) {
    // Check instance methods in current class
    final hasToJsonMethod = classElement.methods.any(
      (method) =>
          method.name == 'toJson' &&
          method.parameters.isEmpty &&
          !method.isStatic,
    );

    if (hasToJsonMethod) {
      return true;
    }

    // Check mixins for toJson method (Freezed generates toJson in mixins)
    final hasMixinWithToJson = classElement.mixins.any(
      (mixin) {
        final mixinElement = mixin.element;
        return mixinElement.methods.any(
          (method) =>
              method.name == 'toJson' &&
              method.parameters.isEmpty &&
              !method.isStatic,
        );
      },
    );

    if (hasMixinWithToJson) {
      return true;
    }

    // Check superclass
    final supertype = classElement.supertype;
    if (supertype != null && supertype.element.name != 'Object') {
      final supertypeElement = supertype.element;
      if (supertypeElement is ClassElement && _hasToJsonMethod(supertypeElement)) {
        return true;
      }
    }

    return false;
  }

  /// Check if type supports generic JSON serialization
  static bool _hasGenericJsonSupport(DartType dartType) {
    if (dartType is! InterfaceType) {
      return false;
    }

    final classElement = dartType.element;
    if (classElement is! ClassElement) {
      return false;
    }

    // Check for fromJson constructor (accepts 2 or 3 parameters)
    final hasGenericFromJson = classElement.constructors.any(
      (constructor) =>
          constructor.name == 'fromJson' &&
          (constructor.parameters.length == 2 ||
              constructor.parameters.length == 3),
    );

    // Check for toJson method (accepts 1 or 2 parameters)
    final hasGenericToJson = classElement.methods.any(
      (method) =>
          method.name == 'toJson' &&
          (method.parameters.length == 1 || method.parameters.length == 2) &&
          !method.isStatic,
    );

    return hasGenericFromJson && hasGenericToJson;
  }

  /// Check if a type name represents a known Firestore type
  static bool _isKnownFirestoreType(String typeName) {
    const knownTypes = {
      'String',
      'int',
      'double',
      'bool',
      'DateTime',
      'Duration',
      'List',
      'Map',
      'Set',
      'Uint8List',
      'GeoPoint',
      'DocumentReference',
      'Timestamp',
      'Blob',
      'FieldValue',
    };

    // Check exact matches
    if (knownTypes.contains(typeName)) {
      return true;
    }

    // Check generic types (e.g., List<String>, Map<String, dynamic>)
    for (final knownType in knownTypes) {
      if (typeName.startsWith('$knownType<')) {
        return true;
      }
    }

    return false;
  }

  /// Get the appropriate FirestoreConverter for a given FirestoreType and DartType
  static String getConverterForFirestoreType(
    FirestoreType firestoreType,
    DartType dartType, {
    bool isNullable = false,
  }) {
    String converter;

    // Handle special cases based on Dart type first
    final typeName = dartType.getDisplayString(withNullability: false);
    if (typeName == 'Duration') {
      converter = 'const DurationConverter()';
    } else {
      // Handle based on FirestoreType
      switch (firestoreType) {
        case FirestoreType.string:
          converter = 'null'; // No conversion needed for strings
          break;
        case FirestoreType.integer:
          converter = 'null'; // No conversion needed for integers
          break;
        case FirestoreType.double:
          converter = 'null'; // No conversion needed for doubles
          break;
        case FirestoreType.boolean:
          converter = 'null'; // No conversion needed for booleans
          break;
        case FirestoreType.timestamp:
          converter = 'const DateTimeConverter()';
          break;
        case FirestoreType.bytes:
          converter = 'const BytesConverter()';
          break;
        case FirestoreType.geoPoint:
          converter = 'const GeoPointConverter()';
          break;
        case FirestoreType.reference:
          converter = 'const DocumentReferenceConverter()';
          break;
        case FirestoreType.array:
          converter =
              'null'; // Will be handled by ListConverter with element converter
          break;
        case FirestoreType.map:
          converter =
              'null'; // Will be handled by MapConverter with value converter
          break;
        case FirestoreType.null_:
          converter = 'null'; // Null values don't need conversion
          break;
        case FirestoreType.object:
          // For custom objects, use ObjectConverter with the type's fromJson/toJson
          converter =
              'ObjectConverter<$typeName>($typeName.fromJson, (obj) => obj.toJson())';
          break;
      }
    }

    // Wrap with NullableConverter if needed
    if (isNullable && converter != 'null') {
      converter = 'NullableConverter($converter)';
    }

    return converter;
  }
}
