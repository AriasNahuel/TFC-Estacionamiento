import { describe, expect, it } from 'vitest'
import { clearTerminalCredential, EncryptedTerminalCredentialStorage, migrateLegacyTerminalCredential, readTerminalCredential, restoreTerminalCredential, terminalCredentialKey, validateAndStoreTerminalCredential, type TerminalCredentialStorage, type TerminalCredentialVaultAdapter } from '../services/terminalCredentials'

function memoryStorage(): TerminalCredentialStorage {
  const values = new Map<string, string>()
  return {
    getItem: async (key) => values.get(key) ?? null,
    setItem: async (key, value) => { values.set(key, value) },
    removeItem: async (key) => { values.delete(key) },
  }
}

function memoryVault(): { adapter: TerminalCredentialVaultAdapter; values: Map<string, unknown> } {
  const values = new Map<string, unknown>()
  return {
    values,
    adapter: {
      get: async (key) => values.get(key),
      add: async (key, value) => {
        if (values.has(key)) throw new Error('duplicate key')
        values.set(key, value)
      },
      put: async (key, value) => { values.set(key, value) },
      delete: async (key) => { values.delete(key) },
    },
  }
}

describe('vinculación de terminal', () => {
  it('valida el carril antes de persistir y recupera la credencial de ese carril', async () => {
    const storage = memoryStorage()
    const credential = 'a'.repeat(64)
    const validate = async (direction: 'entry' | 'exit', value: string) => direction === 'entry' && value === credential

    await validateAndStoreTerminalCredential('entry', ` ${credential} `, validate, storage)

    expect(await restoreTerminalCredential('entry', validate, storage)).toEqual({ status: 'valid', credential })
    expect(await restoreTerminalCredential('exit', validate, storage)).toEqual({ status: 'missing' })
    expect(await readTerminalCredential('entry', storage)).toBe(credential)
    expect(await readTerminalCredential('exit', storage)).toBeNull()
    expect(await storage.getItem(terminalCredentialKey('exit'))).toBeNull()
  })

  it('no persiste una credencial inválida o de otro carril y permite desvincularla', async () => {
    const storage = memoryStorage()
    const credential = 'b'.repeat(64)
    const validate = async (direction: 'entry' | 'exit') => direction === 'exit'

    await expect(validateAndStoreTerminalCredential('entry', credential, validate, storage)).rejects.toThrow(/no es válida/)
    expect(await readTerminalCredential('entry', storage)).toBeNull()

    await validateAndStoreTerminalCredential('exit', credential, validate, storage)
    expect(await readTerminalCredential('exit', storage)).toBe(credential)
    await clearTerminalCredential('exit', storage)
    expect(await readTerminalCredential('exit', storage)).toBeNull()
  })

  it('cifra la credencial antes de persistirla y la recupera desde otra instancia del almacén', async () => {
    const { adapter, values } = memoryVault()
    const firstSession = new EncryptedTerminalCredentialStorage(adapter)
    const secondSession = new EncryptedTerminalCredentialStorage(adapter)
    const credential = 'c'.repeat(64)

    await firstSession.setItem(terminalCredentialKey('entry'), credential)

    expect(JSON.stringify([...values.entries()])).not.toContain(credential)
    expect((values.get('__aes-gcm-key-v1__') as CryptoKey).extractable).toBe(false)
    expect(await secondSession.getItem(terminalCredentialKey('entry'))).toBe(credential)
    expect(await secondSession.getItem(terminalCredentialKey('exit'))).toBeNull()
  })

  it('mueve una credencial heredada a IndexedDB cifrada y la elimina de sessionStorage', async () => {
    const { adapter } = memoryVault()
    const encryptedStorage = new EncryptedTerminalCredentialStorage(adapter)
    const legacyValues = new Map([[terminalCredentialKey('exit'), 'e'.repeat(64)]])
    const legacyStorage = {
      getItem: (key: string) => legacyValues.get(key) ?? null,
      removeItem: (key: string) => { legacyValues.delete(key) },
    }

    expect(await migrateLegacyTerminalCredential('exit', legacyStorage, encryptedStorage)).toBe(true)
    expect(legacyStorage.getItem(terminalCredentialKey('exit'))).toBeNull()
    expect(await encryptedStorage.getItem(terminalCredentialKey('exit'))).toBe('e'.repeat(64))
  })

  it('conserva la credencial ante un bloqueo temporal y la elimina cuando el backend confirma revocación', async () => {
    const storage = memoryStorage()
    const credential = 'd'.repeat(64)
    await storage.setItem(terminalCredentialKey('entry'), credential)

    expect(await restoreTerminalCredential('entry', async () => 'blocked', storage)).toEqual({ status: 'blocked' })
    expect(await readTerminalCredential('entry', storage)).toBe(credential)
    expect(await restoreTerminalCredential('entry', async () => 'revoked', storage)).toEqual({ status: 'revoked' })
    expect(await readTerminalCredential('entry', storage)).toBeNull()
  })
})
