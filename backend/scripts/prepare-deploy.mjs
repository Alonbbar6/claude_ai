// Deploy-time DB preparation for Railway. Idempotent: pushes the schema, then
// seeds the synthetic dataset ONLY if the DB is empty (first deploy). Safe to
// run on every deploy — it will not re-seed or wipe existing data.
import { execSync } from 'node:child_process';
import { PrismaClient } from '@prisma/client';

function run(cmd: string) {
  console.log(`[prepare] $ ${cmd}`);
  execSync(cmd, { stdio: 'inherit' });
}

// 1) Make the DB match the schema (no migration history needed for the demo).
run('npx prisma db push --skip-generate');

// 2) Seed only when empty.
const prisma = new PrismaClient();
try {
  const ingredients = await prisma.ingredient.count();
  if (ingredients === 0) {
    console.log('[prepare] empty DB -> seeding synthetic dataset');
    run('node dist/scripts/seed.js || npx tsx scripts/seed.ts');
  } else {
    console.log(`[prepare] DB already has ${ingredients} ingredients -> skip seed`);
  }
} finally {
  await prisma.$disconnect();
}
