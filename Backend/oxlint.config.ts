import { defineConfig } from 'oxlint'

export default defineConfig({
  categories: {
    correctness: 'error',
    suspicious: 'error',
    perf: 'warn',
  },
  plugins: ['typescript', 'unicorn', 'import'],
  rules: {
    'no-debugger': 'error',
    'no-alert': 'error',
    'no-eval': 'error',
    'no-unused-vars': 'error',
    'typescript/no-explicit-any': 'warn',
    'typescript/no-floating-promises': 'error',
    'typescript/no-unsafe-assignment': 'warn',
    'unicorn/prefer-node-protocol': 'error',
    'import/no-duplicates': 'error',
  },
})
