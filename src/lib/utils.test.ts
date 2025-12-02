import { describe, it, expect } from 'vitest'
import { cn, getErrorMessage } from './utils'

describe('utilities', () => {
  describe('cn (classname merge)', () => {
    it('merges single classname', () => {
      expect(cn('px-2')).toBe('px-2')
    })

    it('merges multiple classnames', () => {
      const result = cn('px-2', 'py-1', 'bg-red-500')
      expect(result).toContain('px-2')
      expect(result).toContain('py-1')
      expect(result).toContain('bg-red-500')
    })

    it('handles conditional classnames', () => {
      const isActive = true
      const result = cn('base-class', isActive && 'active-class')
      expect(result).toContain('base-class')
      expect(result).toContain('active-class')
    })

    it('handles false conditional classnames', () => {
      const isActive = false
      const result = cn('base-class', isActive && 'active-class')
      expect(result).toContain('base-class')
      expect(result).not.toContain('active-class')
    })

    it('removes duplicates and merges tailwind classes', () => {
      const result = cn('px-2', 'px-4')
      expect(result).toContain('px-4')
    })

    it('handles empty inputs', () => {
      const result = cn('', 'px-2', '')
      expect(result).toContain('px-2')
    })

    it('handles undefined and null values', () => {
      const result = cn('px-2', undefined, null, 'py-1')
      expect(result).toContain('px-2')
      expect(result).toContain('py-1')
    })
  })

  describe('getErrorMessage', () => {
    it('extracts message from Error objects', () => {
      const error = new Error('test error message')
      expect(getErrorMessage(error)).toBe('test error message')
    })

    it('returns string errors as-is', () => {
      expect(getErrorMessage('string error')).toBe('string error')
    })

    it('extracts message from objects with message property', () => {
      const error = {
        message: 'custom error',
        code: 'ERR_CODE',
      }
      expect(getErrorMessage(error)).toBe('custom error')
    })

    it('converts unknown types to string', () => {
      expect(getErrorMessage(123)).toBe('123')
    })

    it('converts null to string', () => {
      expect(getErrorMessage(null)).toBe('null')
    })

    it('converts objects without message property to string', () => {
      const result = getErrorMessage({ custom: 'error' })
      expect(result).toContain('Object')
    })

    it('handles TypeError instances', () => {
      const error = new TypeError('type error message')
      expect(getErrorMessage(error)).toBe('type error message')
    })

    it('handles ReferenceError instances', () => {
      const error = new ReferenceError('reference error message')
      expect(getErrorMessage(error)).toBe('reference error message')
    })

    it('converts arrays to string', () => {
      expect(getErrorMessage(['error1', 'error2'])).toBe('error1,error2')
    })

    it('converts undefined to string', () => {
      expect(getErrorMessage(undefined)).toBe('undefined')
    })

    it('handles error-like objects with non-string message', () => {
      const error = {
        message: 123,
      }
      expect(getErrorMessage(error)).toBe('123')
    })
  })
})
