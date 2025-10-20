// functions/.eslintrc.js
module.exports = {
  root: true,
  env: { node: true, es2021: true },
  parser: '@typescript-eslint/parser',
  parserOptions: { project: ['./tsconfig.json'], sourceType: 'module' },
  plugins: ['@typescript-eslint'],
  extends: ['eslint:recommended', 'plugin:@typescript-eslint/recommended'],
  ignorePatterns: ['lib/**', 'node_modules/**'],
  rules: {
    // we intentionally lazy-load heavy deps in CF
    '@typescript-eslint/no-require-imports': 'off',
    // allow `any` in handlers to keep DX simple
    '@typescript-eslint/no-explicit-any': 'off',
    // allow unused if prefixed with underscore
    '@typescript-eslint/no-unused-vars': ['warn', {
      argsIgnorePattern: '^_',
      varsIgnorePattern: '^_',
      ignoreRestSiblings: true,
    }],
    '@typescript-eslint/ban-ts-comment': 'off',
  },
};
