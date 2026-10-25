import {readFileSync} from 'node:fs';
import {rewriteBookLinks,movedPath} from './book-links.mjs';
const input=JSON.parse(readFileSync(0,'utf8'));
const result=input.documents.map(doc=>({path:doc.path,content:rewriteBookLinks(doc.content,doc.path,input.destinations?.[doc.path] ?? (input.source ? movedPath(doc.path,input.source,input.target) : doc.path),input.source,input.target,input.paths,input.mapping,input.assetFallback)}));
process.stdout.write(JSON.stringify(result));
