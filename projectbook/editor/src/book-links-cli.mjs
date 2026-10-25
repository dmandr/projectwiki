import {readFileSync} from 'node:fs';
import {rewriteBookLinks,movedPath} from './book-links.mjs';
const input=JSON.parse(readFileSync(0,'utf8'));
const result=input.documents.map(doc=>({path:doc.path,content:rewriteBookLinks(doc.content,doc.path,movedPath(doc.path,input.source,input.target),input.source,input.target,input.paths)}));
process.stdout.write(JSON.stringify(result));
