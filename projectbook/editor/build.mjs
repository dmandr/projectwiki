import { build } from 'esbuild';
await build({entryPoints:['src/book-links-cli.mjs'],bundle:true,platform:'node',format:'cjs',outfile:'dist/book-links.cjs',target:['node22']});
await build({ entryPoints: ['src/editor.jsx', 'src/tasks-view.jsx', 'src/tree.js', 'src/raw-notes.jsx'], bundle: true, format: 'esm', splitting: true,
  outdir: 'dist/projectbook-editor', minify: true, sourcemap: false, target: ['es2022'],
  define: { 'process.env.NODE_ENV': '"production"' }, loader: { '.woff2': 'file', '.woff': 'file' } });
await build({entryPoints: ['src/names.mjs'], bundle: true, format: 'iife', outfile: 'dist/projectbook-editor/names.js', minify: true, target: ['es2022']});
