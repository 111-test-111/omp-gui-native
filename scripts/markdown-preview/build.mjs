import { build } from 'esbuild';
import { cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';

const output = resolve('../../OMPGUI/Resources/MarkdownPreview');
await mkdir(output, { recursive: true });
// Only generated vendors are replaced. index.html, preview.css and the source
// entry point live in the repository and require no npm at application build time.
await rm(join(output, 'vendor'), { recursive: true, force: true });
await mkdir(join(output, 'vendor'), { recursive: true });
await build({ entryPoints: ['preview.js'], bundle: true, minify: true, format: 'iife',
  target: 'safari18', external: ['katex'], outfile: join(output, 'preview.js'), legalComments: 'eof' });
await build({ entryPoints: ['chat-math.js'], bundle: true, minify: true, format: 'iife',
  target: 'safari18', outfile: join(output, 'chat-math.js'), legalComments: 'eof' });
async function copy(from, to) {
  await mkdir(resolve(to, '..'), { recursive: true });
  await cp(from, to, { recursive: true, filter: path => !path.endsWith('.map') });
}
await copy('node_modules/mathjax/tex-chtml.js', join(output, 'vendor/mathjax/tex-chtml.js'));
await copy('node_modules/mathjax/input/tex/extensions', join(output, 'vendor/mathjax/input/tex/extensions'));
await copy('node_modules/mathjax/ui/safe.js', join(output, 'vendor/mathjax/ui/safe.js'));
await copy('node_modules/@mathjax/mathjax-newcm-font/chtml', join(output, 'vendor/mathjax-newcm/chtml'));
// TeX font extensions have separate CHTML entry points and lazy WOFF2 files.
// Ship their small runtime payloads so \require{...} never reaches a CDN.
for (const name of ['mhchem', 'bbm', 'bboldx', 'dsfont']) {
  const packageName = `mathjax-${name}-font-extension`;
  await copy(`node_modules/@mathjax/${packageName}/chtml.js`, join(output, `vendor/${packageName}/chtml.js`));
  await copy(`node_modules/@mathjax/${packageName}/chtml`, join(output, `vendor/${packageName}/chtml`));
}
const licenses = [];
// Include notices of transitive packages that are bundled into preview.js, too.
for (const name of ['markdown-it', 'markdown-it-footnote', 'markdown-it-texmath', 'dompurify',
  'highlight.js', 'linkify-it', 'mdurl', 'punycode.js', 'uc.micro', 'entities', 'mathjax']) {
  const dir = `node_modules/${name}`;
  const pkg = JSON.parse(await readFile(`${dir}/package.json`, 'utf8'));
  const files = (await readdir(dir)).filter(f => /^(license|licence|copying|notice)(\.|$)/i.test(f));
  for (const file of files) licenses.push(`${name} ${pkg.version} — ${file}\n\n${await readFile(`${dir}/${file}`, 'utf8')}`);
}
// npm omits the font package's license files. Preserve its original embedded
// font notices and the complete GUST license alongside the Apache JS license.
licenses.push(await readFile('Font-notices.txt', 'utf8'));
await writeFile(join(output, 'THIRD_PARTY_LICENSES.txt'), licenses.join('\n\n' + '='.repeat(72) + '\n\n').replace(/\r\n/g, '\n').replace(/[ \t]+$/gm, ''));
async function manifest(dir, prefix = '') {
  const result = {};
  for (const file of (await readdir(dir, { withFileTypes: true })).sort((a,b) => a.name.localeCompare(b.name, 'en'))) {
    const key = prefix + file.name;
    if (file.isDirectory()) Object.assign(result, await manifest(join(dir, file.name), key + '/'));
    else {
      const data = await readFile(join(dir, file.name));
      result[key] = { bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') };
    }
  }
  return result;
}
const files = await manifest(join(output, 'vendor'), 'vendor/');
for (const name of ['preview.js', 'chat-math.js', 'chat-math.html']) {
  const data = await readFile(join(output, name));
  files[name] = { bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') };
}
await writeFile(join(output, 'vendor-manifest.json'), JSON.stringify({
  packages: JSON.parse(await readFile('package.json', 'utf8')).dependencies, files
}, null, 2) + '\n');
console.log(`Offline resources: ${Object.values(files).reduce((n, f) => n + f.bytes, 0)} bytes`);
