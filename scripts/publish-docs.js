// Builds the documentation site with Moonwave and publishes it to kashtheking.com/library/:
// the built site is committed into the `library/` folder of the KashTheKing.github.io repo
// (GitHub Pages serves that repo at kashtheking.com). Run: npm run publish:docs
// Same flow as infinite-ocean/scripts/publish-docs.js; only the code path and folder differ.
const { execFileSync, execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const SITE_REPO = process.env.SITE_REPO || "https://github.com/KashTheKing/KashTheKing.github.io.git";
const SITE_DIR = "library";
const root = path.resolve(__dirname, "..");
const out = path.join(root, "build", "site-repo");
const built = path.join(root, "build", "docs");
const git = (args, cwd) => execFileSync("git", args, { cwd, stdio: "inherit" });

execSync("moonwave build --code packages/src --out-dir build/docs", { cwd: root, stdio: "inherit" });
if (!fs.existsSync(path.join(built, "index.html"))) {
	throw new Error("moonwave build produced no index.html");
}

if (!fs.existsSync(path.join(out, ".git"))) {
	fs.mkdirSync(path.dirname(out), { recursive: true });
	git(["clone", "--depth", "1", SITE_REPO, out], root);
} else {
	git(["fetch", "--depth", "1", "origin"], out);
	git(["reset", "--hard", "origin/main"], out);
}
const target = path.join(out, SITE_DIR);
fs.rmSync(target, { recursive: true, force: true });
fs.cpSync(built, target, { recursive: true });
// GitHub Pages runs Jekyll on this repo; keep it from touching the built site
fs.writeFileSync(path.join(target, ".nojekyll"), "");

const short = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: root }).toString().trim();
git(["add", "-A", SITE_DIR], out);
try {
	execFileSync("git", ["diff", "--cached", "--quiet"], { cwd: out });
	console.log("site already up to date");
} catch {
	git(["commit", "-q", "-m", `Library docs from library ${short}`], out);
	git(["push", "-q", "origin", "HEAD:main"], out);
	console.log("published to https://kashtheking.com/library/");
}
