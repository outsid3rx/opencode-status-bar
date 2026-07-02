import * as esbuild from 'esbuild'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

const outFile = '.opencode/plugins/opencode-status-bar.js'

mkdirSync(dirname(outFile), { recursive: true })

await esbuild.build({
  entryPoints: ['src/opencode-status-bar-plugin.ts'],
  outfile: outFile,
  bundle: true,
  platform: 'node',
  target: 'node20',
  format: 'cjs',
  sourcemap: false,
  minify: false,
})

console.log(`Built plugin: ${outFile}`)
