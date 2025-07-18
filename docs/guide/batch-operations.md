# Batch Operations

Batch operations allow you to perform multiple write operations (insert, update, delete, patch) as a single atomic unit. All operations in a batch either succeed together or fail together, ensuring data consistency.

Firestore ODM supports two approaches for batch operations:

1. **Automatic Management** - Using `runBatch()` for simple, automatic handling
2. **Manual Management** - Using `batch()` for fine-grained control

## Automatic Batch Management

The `runBatch()` method automatically manages the batch lifecycle. All operations are queued and committed automatically when the callback completes.

```dart
await odm.runBatch((batch) {
  // Insert multiple users
  batch.users.insert(user1);
  batch.users.insert(user2);
  
  // Update existing posts
  batch.posts.update(updatedPost);
  
  // Delete a document
  batch.users('old_user_id').delete();
  
  // Patch operations with nested fields
  batch.users('user_id').patch(($) => [
    $.profile.bio('Updated bio'),
    $.profile.followers(200),
  ]);
});
```

## Manual Batch Management

For more control over when the batch is committed, use the `batch()` method to create a batch context manually.

```dart
// Create a batch
final batch = odm.batch();

// Add operations
batch.users.insert(user1);
batch.users.insert(user2);
batch.posts.update(post);

// Commit when ready
await batch.commit();
```

## Supported Operations

### Insert Operations

Add new documents to collections:

```dart
await odm.runBatch((batch) {
  batch.users.insert(newUser);
  batch.posts.insert(newPost);
});
```

#### Auto-Generated Document IDs in Batch Operations

You can use auto-generated document IDs in batch operations as well:

```dart
await odm.runBatch((batch) {
  // Using the auto-generated ID constant
  batch.users.insert(User(
    id: FirestoreODM.autoGeneratedId, // Server generates unique ID
    name: 'Batch User 1',
    email: 'batch1@example.com',
  ));
  
  // Another auto-generated ID
  batch.users.insert(User(
    id: FirestoreODM.autoGeneratedId, // Server generates unique ID
    name: 'Batch User 2',
    email: 'batch2@example.com',
  ));
  
  // Mix with custom IDs
  batch.users.insert(User(
    id: 'custom-batch-user',
    name: 'Custom Batch User',
    email: 'custom@example.com',
  ));
});
```

### Update Operations

Update existing documents (requires document ID):

```dart
await odm.runBatch((batch) {
  batch.users.update(updatedUser);
  batch.posts.update(updatedPost);
});
```

### Upsert Operations

Insert or update documents (merge if exists):

```dart
await odm.runBatch((batch) {
  batch.users.upsert(userToUpsert);
  batch.posts.upsert(postToUpsert);
});
```

### Delete Operations

Remove documents from collections:

```dart
await odm.runBatch((batch) {
  batch.users('user_id').delete();
  batch.posts('post_id').delete();
});
```

### Patch Operations

Update specific fields without replacing the entire document:

```dart
await odm.runBatch((batch) {
  batch.users('user_id').patch(($) => [
    $.name('New Name'),
    $.age(30),
    $.profile.bio('Updated bio'),
    $.profile.socialLinks.setKey('twitter', '@newhandle'),
  ]);
});
```

## Subcollection Support

Batch operations fully support subcollections, allowing you to perform operations on nested document structures:

```dart
await odm.runBatch((batch) {
  // Insert into user's posts subcollection
  batch.users('user_id').posts.insert(userPost);
  
  // Update a specific post in the subcollection
  batch.users('user_id').posts.update(updatedUserPost);
  
  // Delete from subcollection
  batch.users('user_id').posts('post_id').delete();
  
  // Patch subcollection documents
  batch.users('user_id').posts('post_id').patch(($) => [
    $.title('Updated Title'),
    $.likes.increment(1),
  ]);
});
```

## Mixed Operations Example

You can combine different types of operations in a single batch:

```dart
await odm.runBatch((batch) {
  // Root collection operations
  batch.users.insert(newUser);
  batch.posts.update(existingPost);
  
  // Subcollection operations
  batch.users('author_id').posts.insert(authorPost);
  batch.users('reader_id').posts('post_id').delete();
  
  // Patch operations
  batch.users('user_id').patch(($) => [
    $.lastActivity(DateTime.now()),
    $.profile.followers.increment(1),
  ]);
});
```

## Error Handling

Batch operations are atomic - if any operation fails, the entire batch is rolled back:

```dart
try {
  await odm.runBatch((batch) {
    batch.users.insert(user1);
    batch.users.insert(user2); // If this fails...
    batch.posts.insert(post);  // ...this won't be executed
  });
} catch (e) {
  print('Batch operation failed: $e');
  // No partial changes were made
}
```

## Batch Limitations

- Maximum 500 operations per batch (Firestore limitation)
- All operations must be writes (no reads allowed in batch)
- Operations are not guaranteed to execute in order
- Each operation counts toward your Firestore write quota

## Performance Considerations

Batch operations are more efficient than individual writes because:

- Reduced network round trips
- Lower latency for multiple operations
- Atomic consistency guarantees
- Better throughput for bulk operations

## Best Practices

1. **Group Related Operations**: Batch operations that should succeed or fail together
2. **Limit Batch Size**: Stay well under the 500 operation limit for better performance
3. **Handle Errors Gracefully**: Always wrap batch operations in try-catch blocks
4. **Use Appropriate Method**: Choose `runBatch()` for simplicity, `batch()` for control
5. **Consider Subcollections**: Leverage subcollection support for hierarchical data

## Comparison with Transactions

| Feature | Batch Operations | Transactions |
|---------|------------------|--------------|
| **Reads** | ❌ Not allowed | ✅ Supported |
| **Writes** | ✅ Up to 500 | ✅ Unlimited |
| **Atomicity** | ✅ All or nothing | ✅ All or nothing |
| **Performance** | ⚡ High throughput | 🐌 Lower throughput |
| **Use Case** | Bulk writes | Read-then-write |

Choose batch operations for pure write scenarios and transactions when you need to read data before writing.