import type { Direction } from '../domain/parking'

export interface TerminalCredentialStorage {
  getItem(key: string): Promise<string | null>
  setItem(key: string, value: string): Promise<void>
  removeItem(key: string): Promise<void>
}

export interface TerminalCredentialVaultAdapter {
  get(key: string): Promise<unknown | undefined>
  add(key: string, value: unknown): Promise<void>
  put(key: string, value: unknown): Promise<void>
  delete(key: string): Promise<void>
}

interface EncryptedCredential {
  version: 1
  iv: ArrayBuffer
  ciphertext: ArrayBuffer
}

const databaseName = 'tfc-terminal-credential-vault'
const storeName = 'encrypted-items'
const cryptoKeyName = '__aes-gcm-key-v1__'
const encoder = new TextEncoder()

function openDatabase(): Promise<IDBDatabase> {
  if (typeof indexedDB === 'undefined') return Promise.reject(new Error('IndexedDB no está disponible en este origen.'))
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1)
    request.onupgradeneeded = () => request.result.createObjectStore(storeName)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('No se pudo abrir el almacén cifrado de terminales.'))
    request.onblocked = () => reject(new Error('El almacén cifrado está bloqueado por otra pestaña.'))
  })
}

const idbAdapter: TerminalCredentialVaultAdapter = {
  async get(key) {
    const db = await openDatabase()
    try {
      return await new Promise((resolve, reject) => {
        const request = db.transaction(storeName, 'readonly').objectStore(storeName).get(key)
        request.onsuccess = () => resolve(request.result as unknown | undefined)
        request.onerror = () => reject(request.error)
      })
    } finally { db.close() }
  },
  async add(key, value) {
    const db = await openDatabase()
    try {
      await new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(storeName, 'readwrite')
        transaction.objectStore(storeName).add(value, key)
        transaction.oncomplete = () => resolve()
        transaction.onerror = () => reject(transaction.error)
        transaction.onabort = () => reject(transaction.error ?? new Error('No se pudo guardar la clave de cifrado.'))
      })
    } finally { db.close() }
  },
  async put(key, value) {
    const db = await openDatabase()
    try {
      await new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(storeName, 'readwrite')
        transaction.objectStore(storeName).put(value, key)
        transaction.oncomplete = () => resolve()
        transaction.onerror = () => reject(transaction.error)
        transaction.onabort = () => reject(transaction.error ?? new Error('No se pudo guardar la credencial cifrada.'))
      })
    } finally { db.close() }
  },
  async delete(key) {
    const db = await openDatabase()
    try {
      await new Promise<void>((resolve, reject) => {
        const transaction = db.transaction(storeName, 'readwrite')
        transaction.objectStore(storeName).delete(key)
        transaction.oncomplete = () => resolve()
        transaction.onerror = () => reject(transaction.error)
        transaction.onabort = () => reject(transaction.error ?? new Error('No se pudo eliminar la credencial local.'))
      })
    } finally { db.close() }
  },
}

export class EncryptedTerminalCredentialStorage implements TerminalCredentialStorage {
  constructor(private readonly adapter: TerminalCredentialVaultAdapter = idbAdapter) {}

  private async getEncryptionKey(): Promise<CryptoKey> {
    const current = await this.adapter.get(cryptoKeyName)
    if (current) return current as CryptoKey
    if (!globalThis.crypto?.subtle) throw new Error('WebCrypto no está disponible en este origen seguro.')
    const candidate = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'])
    try {
      await this.adapter.add(cryptoKeyName, candidate)
      return candidate
    } catch (error) {
      // Si otra pestaña creó la clave a la vez, usar la clave que quedó guardada.
      const winner = await this.adapter.get(cryptoKeyName)
      if (winner) return winner as CryptoKey
      throw error
    }
  }

  async getItem(key: string): Promise<string | null> {
    const record = await this.adapter.get(key) as EncryptedCredential | undefined
    if (!record) return null
    if (record.version !== 1) throw new Error('La credencial cifrada tiene una versión desconocida.')
    try {
      const plaintext = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: record.iv, additionalData: encoder.encode(`tfc-terminal:${key}`) },
        await this.getEncryptionKey(),
        record.ciphertext,
      )
      return new TextDecoder().decode(plaintext)
    } catch {
      await this.adapter.delete(key)
      throw new Error('No se pudo descifrar la credencial local; se eliminó el registro dañado y hay que vincular de nuevo.')
    }
  }

  async setItem(key: string, value: string): Promise<void> {
    const iv = crypto.getRandomValues(new Uint8Array(12))
    const ciphertext = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv, additionalData: encoder.encode(`tfc-terminal:${key}`) },
      await this.getEncryptionKey(),
      encoder.encode(value),
    )
    await this.adapter.put(key, { version: 1, iv: iv.buffer, ciphertext })
  }

  removeItem(key: string): Promise<void> { return this.adapter.delete(key) }
}

export const terminalCredentialStorage = new EncryptedTerminalCredentialStorage()

export function terminalCredentialKey(direction: Direction) {
  return `estacionamiento:terminal-${direction}`
}

export interface LegacyTerminalCredentialStorage {
  getItem(key: string): string | null
  removeItem(key: string): void
}

export async function migrateLegacyTerminalCredential(
  direction: Direction,
  legacyStorage: LegacyTerminalCredentialStorage,
  storage: TerminalCredentialStorage,
) {
  const key = terminalCredentialKey(direction)
  const legacyCredential = legacyStorage.getItem(key)
  if (!legacyCredential) return false
  try {
    if (!await storage.getItem(key)) await storage.setItem(key, legacyCredential)
    return true
  } finally {
    legacyStorage.removeItem(key)
  }
}

export async function readTerminalCredential(direction: Direction, storage: TerminalCredentialStorage) {
  return storage.getItem(terminalCredentialKey(direction))
}

export async function clearTerminalCredential(direction: Direction, storage: TerminalCredentialStorage) {
  await storage.removeItem(terminalCredentialKey(direction))
}

export type TerminalCredentialStatus = 'valid' | 'invalid' | 'revoked' | 'blocked'

export async function restoreTerminalCredential(
  direction: Direction,
  validate: (direction: Direction, credential: string) => Promise<boolean | TerminalCredentialStatus>,
  storage: TerminalCredentialStorage,
) {
  const credential = await readTerminalCredential(direction, storage)
  if (!credential) return { status: 'missing' } as const
  const result = await validate(direction, credential)
  if (result === 'blocked') return { status: 'blocked' } as const
  if (result === false || result === 'invalid' || result === 'revoked') {
    await clearTerminalCredential(direction, storage)
    return { status: result === 'revoked' ? 'revoked' : 'invalid' } as const
  }
  return { status: 'valid', credential } as const
}

export async function validateAndStoreTerminalCredential(
  direction: Direction,
  input: string,
  validate: (direction: Direction, credential: string) => Promise<boolean>,
  storage: TerminalCredentialStorage,
) {
  const credential = input.trim()
  if (credential.length < 40) throw new Error('La credencial debe tener al menos 40 caracteres.')
  if (!await validate(direction, credential)) {
    throw new Error(`La credencial no es válida para la terminal de ${direction === 'entry' ? 'entrada' : 'salida'}, fue revocada o está temporalmente bloqueada.`)
  }
  await storage.setItem(terminalCredentialKey(direction), credential)
  return credential
}
