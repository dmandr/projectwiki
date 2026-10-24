// File/Blob values stay in IndexedDB alongside Markdown, never in the Git book.
const database = new Promise((resolve, reject) => {
  const request = indexedDB.open('projectbook-drafts', 1);
  request.onupgradeneeded = () => request.result.createObjectStore('drafts');
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});
export async function draftStore(mode, key, value) {
  const db = await database;
  return new Promise((resolve, reject) => {
    const tx = db.transaction('drafts', mode === 'get' ? 'readonly' : 'readwrite');
    const store = tx.objectStore('drafts');
    const request = mode === 'get' ? store.get(key) : mode === 'delete' ? store.delete(key) : store.put(value, key);
    tx.oncomplete = () => resolve(request.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('Draft storage was interrupted.'));
  });
}
