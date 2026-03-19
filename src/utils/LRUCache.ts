/**
 * LRU Cache genérico con tamaño máximo configurable
 * Cuando se alcanza el límite, elimina la entrada menos recientemente usada
 */
export class LRUCache<K, V> {
  private cache = new Map<K, V>()
  private readonly maxSize: number

  constructor(maxSize: number) {
    if (maxSize < 1) throw new Error('LRU maxSize must be at least 1')
    this.maxSize = maxSize
  }

  get(key: K): V | undefined {
    const value = this.cache.get(key)
    if (value !== undefined) {
      // Mover al final (más reciente) — Map mantiene orden de inserción
      this.cache.delete(key)
      this.cache.set(key, value)
    }
    return value
  }

  has(key: K): boolean {
    return this.cache.has(key)
  }

  set(key: K, value: V): void {
    // Si la key ya existe, eliminarla para reposicionarla al final
    if (this.cache.has(key)) {
      this.cache.delete(key)
    } else if (this.cache.size >= this.maxSize) {
      // Eliminar la entrada más antigua (primera del Map)
      const oldestKey = this.cache.keys().next().value
      if (oldestKey !== undefined) {
        this.cache.delete(oldestKey)
      }
    }
    this.cache.set(key, value)
  }

  delete(key: K): boolean {
    return this.cache.delete(key)
  }

  clear(): void {
    this.cache.clear()
  }

  get size(): number {
    return this.cache.size
  }

  /** Iterador sobre las entradas (más antigua → más reciente) */
  entries(): IterableIterator<[K, V]> {
    return this.cache.entries()
  }

  /** Iterador sobre las keys */
  keys(): IterableIterator<K> {
    return this.cache.keys()
  }

  /** Iterador sobre los values */
  values(): IterableIterator<V> {
    return this.cache.values()
  }

  /** Para uso en forEach, compatible con Map API */
  forEach(callbackfn: (value: V, key: K) => void): void {
    this.cache.forEach(callbackfn)
  }
}
