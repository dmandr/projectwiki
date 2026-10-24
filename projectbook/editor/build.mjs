import { build } from 'esbuild';
await build({ entryPoints: ['src/editor.jsx'], bundle: true, format: 'esm', splitting: true,
  outdir: 'dist/projectbook-editor', minify: true, sourcemap: false, target: ['es2022'],
  define: { 'process.env.NODE_ENV': '"production"' }, loader: { '.woff2': 'file', '.woff': 'file' } });
