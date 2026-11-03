// Save texture-owned files without changing the shared worktree or index.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const root = path.resolve(__dirname, '../..');
const out = __dirname;
const branch = 'codex/texture-hd-p2';
const gitExe = process.env.TEXTURE_GIT || 'git.exe';
const read = name => JSON.parse(fs.readFileSync(path.join(out, name), 'utf8').replace(/^\uFEFF/, ''));
const write = (name, value) => fs.writeFileSync(path.join(out, name), JSON.stringify(value, null, 2) + '\n');
const hash = (bytes, kind = 'sha256') => crypto.createHash(kind).update(bytes).digest('hex');
const blobId = bytes => crypto.createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
function git(args, input = undefined) {
  const result = cp.spawnSync(gitExe, ['-c', 'core.multiPackIndex=false', ...args], {
    cwd: root, input, encoding: 'utf8', maxBuffer: 128 * 1024 * 1024, timeout: 120000, windowsHide: true
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr.slice(-4000));
  return result.stdout.trimEnd();
}
function header(name, oid = 'inline') {
  assert(!name.startsWith('/') && !/[\r\n]/.test(name) && name.split('/').every(p => p && p !== '.' && p !== '..'));
  return `M 100644 ${oid} ${JSON.stringify(name)}\n`;
}
function tree(commit) {
  return new Map(git(['ls-tree', '-r', '-z', commit]).split('\0').filter(Boolean).map(line => {
    const tab = line.indexOf('\t');
    return [line.slice(tab + 1), line.slice(0, tab).split(' ')[2]];
  }));
}
function walk(folder) {
  const files = [];
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    assert(!entry.isSymbolicLink(), 'Unexpected symlink: ' + entry.name);
    if (entry.name === '__pycache__') continue;
    const full = path.join(folder, entry.name);
    if (entry.isDirectory()) files.push(...walk(full));
    else if (entry.isFile() && !/\.(?:pyc|log|tmp)$/.test(entry.name)) files.push(full);
  }
  return files;
}
async function main() {
  assert.equal(blobId(Buffer.alloc(0)), 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391');
  assert.equal(header('a b/x.png'), 'M 100644 inline "a b/x.png"\n');
  assert.throws(() => header('../outside'));
  const progress = read('p4-progress.json');
  assert.equal(progress.status, 'completed');
  assert.equal(progress.next_batch, null);
  assert.equal(progress.completed_files, 5065);
  const p5 = read('p5-progress.json');
  const lastBatch = p5.completed_batches.at(-1);
  assert(/^batch-\d{3}$/.test(lastBatch));
  const lastNumber = Number(lastBatch.slice(6));
  assert(lastNumber >= 817 && lastNumber <= 857);
  const checkpoint = read(`p5-evidence/${lastBatch}/checkpoint-verification.json`);
  assert.equal(checkpoint.status, 'passed');
  assert.equal(checkpoint.next_batch, p5.next_batch);
  const allComplete = p5.status === 'completed';
  if (allComplete) {
    const finalReport = read('p5-evidence/checkpoint-verification.json');
    assert.equal(lastNumber, 857);
    assert.equal(p5.completed_files, 1850);
    assert.equal(finalReport.status, 'passed');
    assert.equal(finalReport.remaining, 0);
    assert.equal(read('execution-plan/plan.json').status, 'completed');
  }
  const base = git(['rev-parse', `refs/heads/${branch}`]);
  const parent = tree(base);
  const sharedBranch = git(['branch', '--show-current']);
  assert.notEqual(sharedBranch, branch, 'Use the normal checkout workflow when already on the feature branch.');
  const indexPath = path.resolve(root, git(['rev-parse', '--git-path', 'index']));
  const initialIndex = hash(fs.readFileSync(indexPath));
  const initialHead = git(['rev-parse', 'HEAD']);
  const applied = [];
  for (let number = 1; number <= lastNumber; number++) {
    const name = `batch-${String(number).padStart(3, '0')}/manifest.json`;
    if (fs.existsSync(path.join(out, name))) applied.push(...read(name).entries);
  }
  assert.equal(applied.length, read('inventory.json').applied);
  const drift = read('p5-evidence/prior-phase-worktree-drift.json');
  const driftBySource = new Map(drift.entries.map(entry => [entry.source, entry]));
  const inheritedApplied = new Map();
  for (const entry of applied) {
    assert(entry.source.startsWith('Graphics/') || entry.source.startsWith('Data/localization/'));
    const current = hash(fs.readFileSync(path.join(root, entry.source)));
    if (current === entry.after_sha256) continue;
    const observed = driftBySource.get(entry.source);
    assert(observed, 'Unrecorded runtime image difference: ' + entry.source);
    assert.equal(current, observed.observed_worktree_sha256, entry.source);
    assert.equal(entry.before_sha256, current, entry.source);
    assert.equal(entry.after_sha256, observed.accepted_sha256, entry.source);
    assert(observed.accepted_archive.startsWith('output/texture-hd/batch-060/ready/'));
    const accepted = fs.readFileSync(path.join(root, observed.accepted_archive));
    assert.equal(hash(accepted), entry.after_sha256, entry.source);
    assert.equal(parent.get(entry.source), blobId(accepted), 'Parent accepted image differs: ' + entry.source);
    inheritedApplied.set(entry.source, parent.get(entry.source));
  }
  assert.equal(inheritedApplied.size, drift.entries.length);
  const excluded = new Set(['output/texture-hd/commit-receipt.json']);
  const files = walk(out).map(p => path.relative(root, p).replaceAll('\\', '/')).filter(p => !excluded.has(p));
  const paths = [...new Set([...files, ...applied.filter(e => !inheritedApplied.has(e.source)).map(e => e.source), 'scripts/graphics/texture_batch.py'])].sort();
  const allowed = new Set(applied.map(e => e.source));
  assert(paths.every(p => p.startsWith('output/texture-hd/') || p === 'scripts/graphics/texture_batch.py' || allowed.has(p)));
  write('commit-scope.json', {
    branch, base_commit: base, shared_worktree_branch: sharedBranch, runtime_images: applied.length,
    record_files: paths.length - (applied.length - inheritedApplied.size) - 1, total_files: paths.length,
    inherited_accepted_runtime_images: [...inheritedApplied.keys()],
    preserved_worktree_drift: 'output/texture-hd/p5-evidence/prior-phase-worktree-drift.json',
    included_roots: ['output/texture-hd', 'scripts/graphics/texture_batch.py', 'manifest-verified applied images'],
    excluded: 'Concurrent source, localization, Android, build and multiplayer edits; raw logs, bytecode and self-referencing commit receipt.',
    preserved_catalog_deltas: 'output/texture-hd/batch-060/catalog-changes.json',
    checkpoint: { p3: 'completed through batch-540', p4: progress, p5 }, paths
  });
  fs.writeFileSync(path.join(out, 'commit-paths.txt'), paths.join('\n') + '\n');
  const expected = new Map();
  let byteCount = 0;
  console.log(`VERIFYING_BYTES files=${paths.length}`);
  for (let i = 0; i < paths.length; i++) {
    const bytes = fs.readFileSync(path.join(root, paths[i]));
    byteCount += bytes.length;
    expected.set(paths[i], blobId(bytes));
    if ((i + 1) % 5000 === 0) console.log(`HASHED ${i + 1}/${paths.length}`);
  }
  const changes = paths.filter(p => parent.get(p) !== expected.get(p));
  assert(changes.length > 0);
  console.log(JSON.stringify({ branch, base, total_files: paths.length, changed_files: changes.length, verified_bytes: byteCount, commit_requested: process.argv.includes('--commit') }));
  if (!process.argv.includes('--commit')) return;
  const temporary = fs.mkdtempSync(path.join(root, 'temp/texture-packed-commit-'));
  assert(path.relative(path.join(root, 'temp'), temporary).startsWith('texture-packed-commit-'));
  let child;
  let timer;
  try {
    const known = new Set(parent.values());
    const author = git(['var', 'GIT_AUTHOR_IDENT']);
    const committer = git(['var', 'GIT_COMMITTER_IDENT']);
    const message = Buffer.from(allComplete
      ? 'feat(graphics): complete P5 texture audit and recovery validation\n\nComplete batches 817-857: 1850 preserved, no new image replacements or pending candidates. Save exact pixel/alpha backups and deliveries, reference audits, 1032 verified native integer-scale outputs, 2384 battler cases, 119200 selection states, archive/editor checks and explicit filename-resolution compatibility findings.\nAll 18665 planned images are resolved on the accepted feature branch: 267 enhancements, one container-only repair, 18397 preserved, zero pending. Inherit six accepted P2 image blobs while preserving the shared worktree originals and recording that difference.\nFull gameplay and Android device/release validation remain outside this result. Concurrent source/localization/build edits and the shared HEAD/index are preserved; no push.\n'
      : `feat(graphics): audit and preserve P5 texture batch ${lastNumber}\n\nReview ${checkpoint.files} archive images: ${checkpoint.applied} applied, ${checkpoint.preserved} preserved with exact source bytes, dimensions and alpha. Save ${checkpoint.pixel_match_sources} decoded-pixel duplicate relationships, source/data reference audits and native compatibility evidence.\nExplicit archive rendering does not certify ordinary map selection or substitution for current cropped assets. Next batch is ${p5.next_batch}; ${p5.remaining_files} P5 files remain.\nScope excludes concurrent source, localization, build and multiplayer edits.\n`);
    child = cp.spawn(gitExe, ['-c', 'core.multiPackIndex=false', 'fast-import', '--quiet', '--done', '--export-marks=' + path.join(temporary, 'marks')], {
      cwd: root, windowsHide: true, stdio: ['pipe', 'ignore', 'pipe'], env: { ...process.env, GIT_TERMINAL_PROMPT: '0' }
    });
    let errors = '';
    child.stderr.on('data', chunk => { errors = (errors + chunk.toString('utf8')).slice(-16000); });
    const finished = new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', code => code === 0 ? resolve() : reject(new Error(`fast-import exit ${code}: ${errors}`)));
    });
    finished.catch(() => {});
    child.stdin.on('error', () => {});
    timer = setTimeout(() => child.kill(), 300000);
    async function send(bytes) { if (!child.stdin.write(bytes)) await once(child.stdin, 'drain'); }
    await send(`commit refs/heads/${branch}\nmark :1\nauthor ${author}\ncommitter ${committer}\ndata ${message.length}\n`);
    await send(message);
    await send(`\nfrom ${base}\n`);
    for (let i = 0; i < changes.length; i++) {
      const name = changes[i];
      const oid = expected.get(name);
      if (known.has(oid)) await send(header(name, oid));
      else {
        const bytes = fs.readFileSync(path.join(root, name));
        assert.equal(blobId(bytes), oid, 'File changed while saving: ' + name);
        await send(header(name) + `data ${bytes.length}\n`);
        await send(bytes);
        await send('\n');
        known.add(oid);
      }
      if ((i + 1) % 3000 === 0) console.log(`PACKED ${i + 1}/${changes.length}`);
    }
    child.stdin.end('\ndone\n');
    await finished;
    clearTimeout(timer);
    const commit = git(['rev-parse', `refs/heads/${branch}`]);
    assert.equal(fs.readFileSync(path.join(temporary, 'marks'), 'utf8').trim().split(' ')[1], commit);
    assert.equal(git(['rev-parse', commit + '^']), base);
    const committed = tree(commit);
    for (const name of paths) {
      assert.equal(committed.get(name), expected.get(name), 'Committed bytes differ: ' + name);
      assert.equal(blobId(fs.readFileSync(path.join(root, name))), expected.get(name), 'Working bytes changed: ' + name);
    }
    for (const [name, oid] of inheritedApplied) {
      assert.equal(committed.get(name), oid, 'Inherited accepted image differs: ' + name);
      assert.equal(hash(fs.readFileSync(path.join(root, name))), driftBySource.get(name).observed_worktree_sha256, 'Preserved working image changed: ' + name);
    }
    const actual = git(['diff-tree', '--no-commit-id', '-r', '--name-only', '-z', base, commit]).split('\0').filter(Boolean).sort();
    assert.deepEqual(actual, changes);
    assert.equal(git(['branch', '--show-current']), sharedBranch);
    assert.equal(git(['rev-parse', 'HEAD']), initialHead);
    assert.equal(hash(fs.readFileSync(indexPath)), initialIndex);
    const receipt = {
      status: 'committed', branch, commit, base, changed_paths: actual.length, runtime_images: applied.length,
      inherited_accepted_runtime_images: inheritedApplied.size, worktree_image_differences_preserved: inheritedApplied.size,
      files_byte_verified: paths.length, shared_worktree_branch_before: sharedBranch,
      shared_worktree_branch_after: sharedBranch, shared_index_unchanged: true, shared_index_used: false,
      pushed: false, p4_completed_through: 'batch-816', p4_next_batch: null,
      p5_completed_through: lastBatch, p5_next_batch: p5.next_batch, next_global_batch: p5.next_batch,
      method: 'Git packed import with manifest validation, exact committed-byte verification and shared HEAD/index checks'
    };
    write('commit-receipt.json', receipt);
    console.log(JSON.stringify(receipt));
  } finally {
    clearTimeout(timer);
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill();
      await once(child, 'exit').catch(() => {});
    }
    fs.rmSync(temporary, { recursive: true });
    assert(!fs.existsSync(temporary));
  }
}
main().catch(error => { console.error(error.stack); process.exitCode = 1; });
