import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart' hide FunctionType;
import 'package:code_builder/code_builder.dart';
import 'package:firestore_odm_builder/src/utils/converters/converter_factory.dart';
import 'package:firestore_odm_builder/src/utils/converters/type_converter.dart';
import 'package:firestore_odm_builder/src/utils/reference_utils.dart';
import 'package:firestore_odm_builder/src/utils/string_utils.dart';

import '../utils/model_analyzer.dart';
import 'filter_generator.dart';
import 'order_by_generator.dart';
import 'update_generator.dart';
import 'aggregate_generator.dart';

/// Information about a collection annotation extracted from a schema variable
class SchemaCollectionInfo {
  final String path;
  final String modelTypeName;
  final bool isSubcollection;
  final InterfaceType modelType;

  const SchemaCollectionInfo({
    required this.path,
    required this.modelTypeName,
    required this.isSubcollection,
    required this.modelType,
  });
}

/// Generator for schema-based ODM code using code_builder
class SchemaGenerator {
  /// Generate schema class and extensions from annotated variable (with converters)
  static String generateSchemaCode(
    TopLevelVariableElement variableElement,
    List<SchemaCollectionInfo> collections,
  ) {
    final library = Library(
      (b) => b.body.addAll(
        _generateAllLibraryMembers(variableElement, collections),
      ),
    );

    final emitter = DartEmitter(useNullSafetySyntax: true);
    return library.accept(emitter).toString();
  }

  /// Extract the assigned value from a variable element (e.g., "_$TestSchema" from "final testSchema = _$TestSchema;")
  static String _extractAssignedValue(TopLevelVariableElement variableElement) {
    try {
      // Try to get the source location and extract the assigned value
      final source = variableElement.source;
      if (source != null) {
        final contents = source.contents.data;
        final name = variableElement.name;

        // Find the variable declaration line
        final lines = contents.split('\n');
        for (final line in lines) {
          if (line.contains('$name =') && line.contains('_\$')) {
            // Extract the assigned value (everything after '=' and before ';')
            final equalIndex = line.indexOf('$name =');
            if (equalIndex != -1) {
              final afterEqual = line
                  .substring(equalIndex + '$name ='.length)
                  .trim();
              final assignedValue = afterEqual
                  .replaceAll(RegExp(r';.*$'), '')
                  .trim();

              // Validate that it looks like a proper assigned value
              if (assignedValue.isNotEmpty && assignedValue.startsWith('_\$')) {
                return assignedValue;
              }
            }
          }
        }
      }
    } catch (e) {
      // Ignore parsing errors and fall back to convention
    }

    // Fallback: generate from variable name following the convention
    return '_\$${variableElement.name.upperFirst()}';
  }

  static String _generateDocumentClassName(String collectionPath) {
    final className = _generateClassName(collectionPath);
    return '${className}Document';
  }

  static String _generateCollectionClassName(String collectionPath) {
    final className = _generateClassName(collectionPath);
    return '${className}Collection';
  }

  /// Generate document class name from collection path
  /// e.g., "users" -> "UsersDocument", "users2" -> "Users2Document"
  /// e.g., "users/*/posts" -> "UsersCollectionPostsDocument"
  /// e.g., "users/*/posts/*/comments" -> "UsersCollectionPostsCollectionCommentsDocument"
  static String _generateClassName(String collectionPath) {
    return _getSegments(collectionPath).join('Collection');
  }

  static List<String> _getSegments(String collectionPath) {
    // Split path and filter out wildcards
    final segments = collectionPath
        .split('/')
        .where((segment) => segment != '*')
        .toList();

    // Convert each segment to PascalCase and join with underscore
    final capitalizedSegments = segments
        .map((segment) => segment.upperFirst())
        .toList();

    return capitalizedSegments;
  }

  /// Get parent type name from subcollection path
  static String? _getParentTypeFromPath(
    String path,
    List<SchemaCollectionInfo> allCollections,
  ) {
    final segments = path.split('/');
    if (segments.length < 3) return null;

    // For subcollections like "users/*/posts", the parent collection is "users"
    // For nested subcollections like "users/*/posts/*/comments", the parent collection is "users/*/posts"
    // Build the parent path by removing the last segment (subcollection name)
    final parentSegments = segments.sublist(0, segments.length - 1);
    final parentPath = parentSegments.join('/');

    // First try to find exact match
    for (final collection in allCollections) {
      if (collection.path == parentPath) {
        return collection.modelTypeName;
      }
    }

    // If no exact match and parent path contains wildcards, try to find the base collection
    // For example: "users/*" should match "users"
    if (parentPath.contains('*')) {
      // Remove wildcard segments and try to find base collection
      final baseSegments = <String>[];
      for (final segment in parentSegments) {
        if (segment == '*') break;
        baseSegments.add(segment);
      }

      if (baseSegments.isNotEmpty) {
        final basePath = baseSegments.join('/');
        for (final collection in allCollections) {
          if (collection.path == basePath && !collection.isSubcollection) {
            return collection.modelTypeName;
          }
        }
      }
    }

    return null;
  }

  /// Get parent collection path from subcollection path
  /// e.g., "users/*/posts" -> "users"
  /// e.g., "posts/*/comments" -> "posts"
  /// e.g., "users/*/posts/*/comments" -> "users/*/posts"
  static String? _getParentCollectionPath(String subcollectionPath) {
    final segments = subcollectionPath.split('/');
    if (segments.length >= 3) {
      // Return all segments except the last one (which is the subcollection name)
      final parentSegments = segments.take(segments.length - 2).toList();
      if (parentSegments.isNotEmpty) {
        return parentSegments.join('/');
      }
    }
    return null;
  }

  /// Get subcollection name from full path (last segment)
  static String _getSubcollectionName(String path) {
    return path.split('/').last;
  }

  /// Generate all library members
  static List<Spec> _generateAllLibraryMembers(
    TopLevelVariableElement variableElement,
    List<SchemaCollectionInfo> collections,
  ) {
    final specs = <Spec>[];

    // specs.addAll(_generateCollectionIdentifiers(collections));
    // register generators

    // Use variable name for clean class name (e.g., "schema" -> "Schema", "helloSchema" -> "HelloSchema")
    final variableName = variableElement.name;
    final schemaClassName = variableName.upperFirst();

    // Extract the assigned value (e.g., "_$TestSchema") for the const name
    final assignedValue = _extractAssignedValue(variableElement);
    final schemaConstName = assignedValue;

    // Generate the schema class and constant
    specs.addAll(
      _generateSchemaClassAndConstant(schemaClassName, schemaConstName),
    );

    specs.addAll(_generateFilterAndOrderBySelectors(collections));
    // Generate filter and order by builders for each model type

    // Generate ODM extensions
    final odmExtension = _generateODMExtensions(schemaClassName, collections);
    if (odmExtension != null) specs.add(odmExtension);

    // Generate transaction context extensions
    final transactionExtension = _generateTransactionContextExtensions(
      schemaClassName,
      collections,
    );
    if (transactionExtension != null) specs.add(transactionExtension);

    // Generate batch context extensions
    final batchExtension = _generateBatchContextExtensions(
      schemaClassName,
      collections,
    );
    if (batchExtension != null) specs.add(batchExtension);

    // Generate unique document classes for each collection path
    specs.addAll(_generateUniqueDocumentClasses(schemaClassName, collections));

    // Generate document extensions for subcollections (path-specific)
    // specs.addAll(_generateDocumentExtensions(schemaClassName, collections));

    // Generate batch document extensions for subcollections
    specs.addAll(
      _generateBatchDocumentExtensions(schemaClassName, collections),
    );

    specs.addAll(converterFactory.specs);

    return specs;
  }

  /// Generate the schema class and constant instance
  static List<Spec> _generateSchemaClassAndConstant(
    String schemaClassName,
    String originalVariableName,
  ) {
    final specs = <Spec>[];

    // Generate the schema class
    final schemaClass = Class(
      (b) => b
        ..docs.add(
          '/// Generated schema class - dummy class that only serves as type marker',
        )
        ..name = schemaClassName
        ..extend = refer('FirestoreSchema')
        ..constructors.add(Constructor((b) => b..constant = true)),
    );
    specs.add(schemaClass);

    // Generate the const instance
    final constInstance = Field(
      (b) => b
        ..docs.add('/// Generated schema instance')
        ..modifier = FieldModifier.constant
        ..name = originalVariableName
        ..type = refer(schemaClassName)
        ..assignment = refer(schemaClassName).newInstance([]).code,
    );
    specs.add(constInstance);

    return specs;
  }

  /// Generate filter and order by builders for all model types
  static List<Spec> _generateFilterAndOrderBySelectors(
    List<SchemaCollectionInfo> collections,
  ) {
    final specs = <Spec>[];

    for (final type
        in collections
            .expand((c) => run(c.modelType))
            .where(isUserType)
            .whereType<InterfaceType>()
            .map((t) => t.element.thisType)
            .toSet()) {
      // Generate FilterSelector class using ModelAnalysis
      final filterClass =
          FilterGenerator.generateFilterSelectorClassFromAnalysis(type);
      specs.add(filterClass);

      // Generate OrderBySelector class using ModelAnalysis
      final orderByExtension =
          OrderByGenerator.generateOrderBySelectorClassFromAnalysis(type);
      specs.add(orderByExtension);

      // Generate UpdateBuilder extension using ModelAnalysis
      final updateExtension = UpdateGenerator.generateUpdateBuilderClass(type);
      if (updateExtension != null) {
        specs.add(updateExtension);
      }

      // Generate AggregateFieldSelector extension using ModelAnalysis
      final aggregateExtension =
          AggregateGenerator.generateAggregateFieldSelectorFromAnalysis(type);
      specs.add(aggregateExtension);
    }

    return specs;
  }

  /// Generate ODM extensions for the schema
  static Extension? _generateODMExtensions(
    String schemaClassName,
    List<SchemaCollectionInfo> collections,
  ) {
    final rootCollections = collections
        .where((c) => !c.isSubcollection)
        .toList();
    if (rootCollections.isEmpty) return null;

    final methods = <Method>[];

    for (final collection in rootCollections) {
      final documentIdFieldName = ModelAnalyzer.instance.getDocumentIdFieldName(
        collection.modelType,
      );
      final collectionClassName = _generateCollectionClassName(collection.path);
      methods.add(
        Method(
          (b) => b
            ..docs.add('/// Access ${collection.path} collection')
            ..type = MethodType.getter
            ..name = collection.path.camelCase().lowerFirst()
            ..returns = refer(collectionClassName)
            ..lambda = true
            ..body = refer(collectionClassName).newInstance([], {
              'query': refer(
                'firestore',
              ).property('collection').call([literalString(collection.path)]),
              'converter': ConverterFactory.instance
                  .getConverter(collection.modelType)
                  .toConverterExpr(),
              'documentIdField': literalString(documentIdFieldName),
            }).code,
        ),
      );
    }

    return Extension(
      (b) => b
        ..docs.add(
          '/// Extension to add collections to FirestoreODM<$schemaClassName>',
        )
        ..name = '${schemaClassName}ODMExtensions'
        ..on = TypeReference(
          (b) => b
            ..symbol = 'FirestoreODM'
            ..types.add(refer(schemaClassName)),
        )
        ..methods.addAll(methods),
    );
  }

  /// Generate transaction context extensions for the schema
  static Extension? _generateTransactionContextExtensions(
    String schemaClassName,
    List<SchemaCollectionInfo> collections,
  ) {
    final rootCollections = collections
        .where((c) => !c.isSubcollection)
        .toList();
    if (rootCollections.isEmpty) return null;

    final methods = <Method>[];

    for (final collection in rootCollections) {
      final documentIdFieldName = ModelAnalyzer.instance.getDocumentIdFieldName(
        collection.modelType,
      );

      methods.add(
        Method(
          (b) => b
            ..docs.add('/// Access ${collection.path} collection')
            ..type = MethodType.getter
            ..name = collection.path.camelCase().lowerFirst()
            ..returns = TypeReference(
              (b) => b
                ..symbol = 'TransactionCollection'
                ..types.addAll([
                  refer(schemaClassName),
                  refer(collection.modelTypeName),
                ]),
            )
            ..lambda = true
            ..body =
                TypeReference(
                  (b) => b
                    ..symbol = 'TransactionCollection'
                    ..types.addAll([
                      refer(schemaClassName),
                      refer(collection.modelTypeName),
                    ]),
                ).newInstance([], {
                  'transaction': refer('transaction'),
                  'query': refer('ref').property('collection').call([
                    literalString(collection.path),
                  ]),
                  'converter': converterFactory
                      .getConverter(collection.modelType)
                      .toConverterExpr(),
                  'context': refer('this'),
                  'documentIdField': literalString(documentIdFieldName),
                }).code,
        ),
      );
    }

    return Extension(
      (b) => b
        ..docs.add(
          '/// Extension to add collections to TransactionContext<$schemaClassName>',
        )
        ..name = '${schemaClassName}TransactionContextExtensions'
        ..on = TypeReference(
          (b) => b
            ..symbol = 'TransactionContext'
            ..types.add(refer(schemaClassName)),
        )
        ..methods.addAll(methods),
    );
  }

  /// Generate batch context extensions for the schema
  static Extension? _generateBatchContextExtensions(
    String schemaClassName,
    List<SchemaCollectionInfo> collections,
  ) {
    final rootCollections = collections
        .where((c) => !c.isSubcollection)
        .toList();
    if (rootCollections.isEmpty) return null;

    final methods = <Method>[];

    for (final collection in rootCollections) {
      final documentIdFieldName = ModelAnalyzer.instance.getDocumentIdFieldName(
        collection.modelType,
      );
      methods.add(
        Method(
          (b) => b
            ..docs.add('/// Access ${collection.path} collection')
            ..type = MethodType.getter
            ..name = collection.path.camelCase().lowerFirst()
            ..returns = TypeReference(
              (b) => b
                ..symbol = 'BatchCollection'
                ..types.addAll([
                  refer(schemaClassName),
                  refer(collection.modelTypeName),
                ]),
            )
            ..lambda = true
            ..body = TypeReference((b) => b..symbol = 'BatchCollection')
                .newInstance([], {
                  'collection': refer('firestoreInstance')
                      .property('collection')
                      .call([literalString(collection.path)]),
                  'converter': converterFactory
                      .getConverter(collection.modelType)
                      .toConverterExpr(),
                  'documentIdField': literalString(documentIdFieldName),
                  'context': refer('this'),
                })
                .code,
        ),
      );
    }

    return Extension(
      (b) => b
        ..docs.add(
          '/// Extension to add collections to BatchContext<$schemaClassName>',
        )
        ..name = '${schemaClassName}BatchContextExtensions'
        ..on = TypeReference(
          (b) => b
            ..symbol = 'BatchContext'
            ..types.add(refer(schemaClassName)),
        )
        ..methods.addAll(methods),
    );
  }

  /// Generate unique document and collection classes for each collection path
  static List<Spec> _generateUniqueDocumentClasses(
    String schemaClassName,
    List<SchemaCollectionInfo> collections,
  ) {
    final specs = <Spec>[];

    for (final collection in collections) {
      final className = _generateClassName(collection.path);
      final documentClassName = _generateDocumentClassName(collection.path);
      final collectionClassName = _generateCollectionClassName(collection.path);
      final modelType = collection.modelTypeName;

      final methods = <Method>[];

      // patch
      methods.add(
        Method(
          (b) => b
            ..docs.add('/// Gets a document reference with the specified ID')
            ..annotations.add(refer('override'))
            ..name = 'patch'
            ..returns = refer('Future<void>')
            ..requiredParameters.add(
              Parameter(
                (b) => b
                  ..name = 'patches'
                  ..type = FunctionType(
                    (b) => b
                      ..returnType = TypeReferences.listOf(
                        TypeReference((b) => b..symbol = 'UpdateOperation'),
                      )
                      ..requiredParameters.add(
                        TypeReference(
                          (b) => b
                            ..symbol =
                                '${collection.modelType.element3.name3}UpdateBuilder'
                            ..types.addAll(
                              collection.modelType.typeArguments.references,
                            ),
                        ),
                      ),
                  ),
              ),
            )
            ..body = Block.of([
              declareFinal('patchBuilder')
                  .assign(
                    TypeReference(
                      (b) => b
                        ..symbol =
                            '${collection.modelType.element3.name3}UpdateBuilder'
                        ..types.addAll(
                          collection.modelType.typeArguments.references,
                        ),
                    ).newInstance(
                      [],
                      Map.fromIterables(
                        collection.modelType.typeParameters.map(
                          (e) => 'converter${e.name}',
                        ),
                        collection.modelType.typeArguments.map(
                          (e) => converterFactory
                              .getConverter(e)
                              .toConverterExpr(),
                        ),
                      ),
                    ),
                  )
                  .statement,
              declareFinal('operations')
                  .assign(refer('patches').call([refer('patchBuilder')]))
                  .statement,
              refer('DocumentHandler')
                  .property('patch')
                  .call([refer('ref'), refer('operations')])
                  .returned
                  .statement,
            ]),
        ),
      );

      for (final subcol in getSubcollections(collections, collection)) {
        final subcollectionName = _getSubcollectionName(subcol.path);
        final getterName = subcollectionName.camelCase().lowerFirst();
        final documentIdFieldName = ModelAnalyzer.instance
            .getDocumentIdFieldName(subcol.modelType);

        // Generate unique collection class name for this subcollection path
        final collectionClassName = _generateCollectionClassName(subcol.path);
        methods.add(
          Method(
            (b) => b
              ..docs.add('/// Access $subcollectionName subcollection')
              ..type = MethodType.getter
              ..name = getterName
              ..returns = refer(collectionClassName)
              ..lambda = true
              ..body = refer(collectionClassName).newInstance([], {
                'query': refer('ref').property('collection').call([
                  literalString(subcollectionName),
                ]),
                'converter': converterFactory
                    .getConverter(subcol.modelType)
                    .toConverterExpr(),
                'documentIdField': literalString(documentIdFieldName),
              }).code,
          ),
        );
      }

      // Generate document class
      final documentClass = Class(
        (b) => b
          ..docs.add('/// Document class for ${collection.path} collection')
          ..name = documentClassName
          ..extend = TypeReference(
            (b) => b
              ..symbol = 'FirestoreDocument'
              ..types.addAll([refer(schemaClassName), refer(modelType)]),
          )
          ..constructors.add(
            Constructor(
              (b) => b
                ..requiredParameters.addAll([
                  Parameter(
                    (b) => b
                      ..name = 'ref'
                      ..toSuper = true,
                  ),
                  Parameter(
                    (b) => b
                      ..name = 'converter'
                      ..toSuper = true,
                  ),
                  Parameter(
                    (b) => b
                      ..name = 'documentIdField'
                      ..toSuper = true,
                  ),
                ])
                ..constant = false,
            ),
          )
          ..methods.addAll(methods),
      );
      specs.add(documentClass);

      // Generate collection class
      final collectionClass = Class(
        (b) => b
          ..docs.add('/// Collection class for ${collection.path} collection')
          ..name = collectionClassName
          ..extend = TypeReference(
            (b) => b
              ..symbol = 'FirestoreCollection'
              ..types.addAll([refer(schemaClassName), refer(modelType)]),
          )
          ..constructors.add(
            Constructor(
              (b) => b
                ..optionalParameters.addAll([
                  Parameter(
                    (b) => b
                      ..name = 'query'
                      ..required = true
                      ..toSuper = true
                      ..named = true,
                  ),
                  Parameter(
                    (b) => b
                      ..name = 'converter'
                      ..required = true
                      ..toSuper = true
                      ..named = true,
                  ),
                  Parameter(
                    (b) => b
                      ..name = 'documentIdField'
                      ..required = true
                      ..toSuper = true
                      ..named = true,
                  ),
                ])
                ..constant = false,
            ),
          )
          ..methods.addAll([
            Method(
              (b) => b
                ..docs.add(
                  '/// Gets a document reference with the specified ID',
                )
                ..annotations.add(refer('override'))
                ..name = 'doc'
                ..returns = refer(documentClassName)
                ..requiredParameters.add(
                  Parameter(
                    (b) => b
                      ..name = 'id'
                      ..type = refer('String'),
                  ),
                )
                ..lambda = true
                ..body = refer(documentClassName).newInstance([
                  refer('query').property('doc').call([refer('id')]),
                  refer('converter'),
                  refer('documentIdField'),
                ]).code,
            ),
            Method(
              (b) => b
                ..docs.add(
                  '/// Gets a document reference with the specified ID',
                )
                ..annotations.add(refer('override'))
                ..name = 'call'
                ..returns = refer(documentClassName)
                ..requiredParameters.add(
                  Parameter(
                    (b) => b
                      ..name = 'id'
                      ..type = refer('String'),
                  ),
                )
                ..lambda = true
                ..body = refer('doc').call([refer('id')]).code,
            ),
            /*
            

  // @override
  // Future<void> patch(List<UpdateOperation> Function(UpdateBuilder<T> patchBuilder) patches);
  //   final operations = patches(_updateBuilder);
  //   return QueryHandler.patch(query, documentIdField, operations);
  // }
      
      */
            Method(
              (b) => b
                ..docs.add(
                  '/// Gets a document reference with the specified ID',
                )
                ..annotations.add(refer('override'))
                ..name = 'patch'
                ..returns = refer('Future<void>')
                ..requiredParameters.add(
                  Parameter(
                    (b) => b
                      ..name = 'patches'
                      ..type = FunctionType(
                        (b) => b
                          ..returnType = TypeReferences.listOf(
                            TypeReference((b) => b..symbol = 'UpdateOperation'),
                          )
                          ..requiredParameters.add(
                            TypeReference(
                              (b) => b
                                ..symbol =
                                    '${collection.modelType.element3.name3}UpdateBuilder'
                                ..types.addAll(
                                  collection.modelType.typeArguments.references,
                                ),
                            ),
                          ),
                      ),
                  ),
                )
                ..body = Block.of([
                  declareFinal('patchBuilder')
                      .assign(
                        TypeReference(
                          (b) => b
                            ..symbol =
                                '${collection.modelType.element3.name3}UpdateBuilder'
                            ..types.addAll(
                              collection.modelType.typeArguments.references,
                            ),
                        ).newInstance(
                          [],
                          Map.fromIterables(
                            collection.modelType.typeParameters.map(
                              (e) => 'converter${e.name}',
                            ),
                            collection.modelType.typeArguments.map(
                              (e) => converterFactory
                                  .getConverter(e)
                                  .toConverterExpr(),
                            ),
                          ),
                        ),
                      )
                      .statement,
                  declareFinal('operations')
                      .assign(refer('patches').call([refer('patchBuilder')]))
                      .statement,
                  refer('QueryHandler')
                      .property('patch')
                      .call([refer('query'), refer('operations')])
                      .returned
                      .statement,
                ]),
            ),
          ]),
      );
      specs.add(collectionClass);
    }

    return specs;
  }

  /// Generate document extensions for subcollections
  static List<Spec> _generateCollectionIdentifiers(
    List<SchemaCollectionInfo> collections,
  ) {
    return [
      Code('''
/// Identifiers for all Firestore collections in the schema
/// Used to map collection paths to their respective collection classes
/// By combining collection classes (e.g., as tuple types),
/// we can use extension methods with record types to reduce boilerplate
/// Example: (_\$UsersCollection, _\$PostsCollection)
      '''),
      ...collections.toSet().map((c) {
        final className = _generateClassName(c.path);
        return Class(
          (b) => b
            ..name = '_\$${className.upperFirst()}Collection'
            ..modifier = ClassModifier.final$,
        );
      }),
    ];
  }

  static List<SchemaCollectionInfo> getSubcollections(
    List<SchemaCollectionInfo> collections,
    SchemaCollectionInfo parentCollection,
  ) {
    return collections.where((c) {
      final parentPath = _getParentCollectionPath(c.path);
      return c.isSubcollection && parentPath == parentCollection.path;
    }).toList();
  }

  /// Generate document extensions for subcollections
  static List<Spec> _generateDocumentExtensions(
    String schemaClassName,
    List<SchemaCollectionInfo> collections,
  ) {
    final specs = <Spec>[];
    final subcollections = collections.where((c) => c.isSubcollection).toList();

    // Group subcollections by their parent collection path
    final pathGroups = <String, List<SchemaCollectionInfo>>{};
    for (final subcol in subcollections) {
      final parentPath = _getParentCollectionPath(subcol.path);
      if (parentPath != null) {
        pathGroups.putIfAbsent(parentPath, () => []).add(subcol);
      }
    }

    for (final entry in pathGroups.entries) {
      final parentPath = entry.key;
      final subcolsForParent = entry.value;
      final parentDocumentClassName = _generateDocumentClassName(parentPath);

      final methods = <Method>[];

      for (final subcol in subcolsForParent) {
        final subcollectionName = _getSubcollectionName(subcol.path);
        final getterName = subcollectionName.camelCase().lowerFirst();
        final documentIdFieldName = ModelAnalyzer.instance
            .getDocumentIdFieldName(subcol.modelType);

        // Generate unique collection class name for this subcollection path
        final collectionClassName = _generateCollectionClassName(subcol.path);
        methods.add(
          Method(
            (b) => b
              ..docs.add('/// Access $subcollectionName subcollection')
              ..type = MethodType.getter
              ..name = getterName
              ..returns = refer(collectionClassName)
              ..lambda = true
              ..body = refer(collectionClassName).newInstance([], {
                'query': refer('ref').property('collection').call([
                  literalString(subcollectionName),
                ]),
                'converter': converterFactory
                    .getConverter(subcol.modelType)
                    .toConverterExpr(),
                'documentIdField': literalString(documentIdFieldName),
              }).code,
          ),
        );
      }

      if (methods.isNotEmpty) {
        specs.add(
          Extension(
            (b) => b
              ..docs.add(
                '/// Extension to access subcollections on $parentDocumentClassName',
              )
              ..name = '${parentDocumentClassName}Extensions'
              ..on = refer(parentDocumentClassName)
              ..methods.addAll(methods),
          ),
        );
      }
    }

    return specs;
  }

  /// Generate batch document extensions for subcollections
  static List<Spec> _generateBatchDocumentExtensions(
    String schemaClassName,
    List<SchemaCollectionInfo> collections,
  ) {
    final specs = <Spec>[];
    final subcollections = collections.where((c) => c.isSubcollection).toList();

    // Group subcollections by parent type
    final parentGroups = <String, List<SchemaCollectionInfo>>{};
    for (final subcol in subcollections) {
      final parentType = _getParentTypeFromPath(subcol.path, collections);
      if (parentType != null) {
        parentGroups.putIfAbsent(parentType, () => []).add(subcol);
      }
    }

    for (final entry in parentGroups.entries) {
      final parentType = entry.key;
      final subcolsForParent = entry.value;

      final methods = <Method>[];

      for (final subcol in subcolsForParent) {
        final subcollectionName = _getSubcollectionName(subcol.path);
        final getterName = subcollectionName.camelCase().lowerFirst();
        final documentIdFieldName = ModelAnalyzer.instance
            .getDocumentIdFieldName(subcol.modelType);

        methods.add(
          Method(
            (b) => b
              ..docs.add(
                '/// Access $subcollectionName subcollection for batch operations',
              )
              ..type = MethodType.getter
              ..name = getterName
              ..returns = TypeReference(
                (b) => b
                  ..symbol = 'BatchCollection'
                  ..types.addAll([
                    refer(schemaClassName),
                    refer(subcol.modelTypeName),
                  ]),
              )
              ..lambda = true
              ..body = TypeReference((b) => b..symbol = 'BatchCollection')
                  .newInstance([], {
                    'collection': refer('ref').property('collection').call([
                      literalString(subcollectionName),
                    ]),
                    'converter': converterFactory
                        .getConverter(subcol.modelType)
                        .toConverterExpr(),
                    'documentIdField': literalString(documentIdFieldName),
                    'context': refer('context'),
                  })
                  .code,
          ),
        );
      }

      if (methods.isNotEmpty) {
        specs.add(
          Extension(
            (b) => b
              ..docs.add(
                '/// Extension to access subcollections on $parentType batch document',
              )
              ..name =
                  '${schemaClassName}${parentType}BatchDocumentSubcollectionExtensions'
              ..on = TypeReference(
                (b) => b
                  ..symbol = 'BatchDocument'
                  ..types.addAll([refer(schemaClassName), refer(parentType)]),
              )
              ..methods.addAll(methods),
          ),
        );
      }
    }

    return specs;
  }

  static Iterable<DartType> run(
    DartType type, [
    Element? annotatedElement,
  ]) sync* {
    yield type;

    if (type is! InterfaceType) return;

    final fields = ModelAnalyzer.instance.getFields(type);
    // Recursively find all nested InterfaceTypes in the fields of this type
    for (final field in fields.values) {
      yield* run(field.type, field.element);
    }

    // If this is a ParameterizedType, analyze its type arguments as well
    for (final arg in type.typeArguments) {
      yield* run(arg);
    }
  }
}
