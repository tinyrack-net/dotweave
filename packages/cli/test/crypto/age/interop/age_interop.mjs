// Interop harness for the Dart age implementation, driving the TypeScript
// `age-encryption` npm package installed at packages/cli/node_modules.
//
// Usage (stdin/stdout carry base64 unless noted):
//   node age_interop.mjs keygen
//     -> prints "<identity>\n<recipient>\n"
//   node age_interop.mjs recipient <identity>
//     -> prints "<recipient>\n"
//   node age_interop.mjs encrypt <recipient> [<recipient> ...]
//     stdin: base64 plaintext -> stdout: armored ciphertext (ASCII)
//   node age_interop.mjs decrypt <identity>
//     stdin: armored ciphertext (ASCII) -> stdout: base64 plaintext

// Resolve the package relative to this file so the script works regardless of
// the working directory (pnpm links it under packages/cli/node_modules).
const agePackageUrl = new URL(
  "../../../../../cli/node_modules/age-encryption/dist/index.js",
  import.meta.url,
);
const { Encrypter, Decrypter, armor, generateIdentity, identityToRecipient } =
  await import(agePackageUrl.href);

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks);
}

const [, , command, ...args] = process.argv;

switch (command) {
  case "keygen": {
    const identity = await generateIdentity();
    const recipient = await identityToRecipient(identity);
    process.stdout.write(`${identity}\n${recipient}\n`);
    break;
  }
  case "recipient": {
    const recipient = await identityToRecipient(args[0]);
    process.stdout.write(`${recipient}\n`);
    break;
  }
  case "encrypt": {
    const plaintext = Buffer.from((await readStdin()).toString("ascii"), "base64");
    const encrypter = new Encrypter();
    for (const recipient of args) encrypter.addRecipient(recipient);
    const ciphertext = await encrypter.encrypt(new Uint8Array(plaintext));
    process.stdout.write(armor.encode(ciphertext));
    break;
  }
  case "decrypt": {
    const armored = (await readStdin()).toString("ascii");
    const decrypter = new Decrypter();
    for (const identity of args) decrypter.addIdentity(identity);
    const plaintext = await decrypter.decrypt(armor.decode(armored));
    process.stdout.write(Buffer.from(plaintext).toString("base64"));
    break;
  }
  default:
    process.stderr.write(`unknown command: ${command}\n`);
    process.exit(2);
}
