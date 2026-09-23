// Drives the real page in a real browser and reports what is actually on
// screen. See spec/browser_spec.rb, which starts a server and runs this.
//
// This exists because the other interface tests read app.js as text. They can
// confirm a function is called; they cannot notice that it was called with an
// argument that made the picture disappear, which is the bug it was written to
// catch and did not.
import { chromium } from "playwright-core";
import { readdirSync } from "node:fs";
import { join } from "node:path";

const BASE = process.argv[2];

// Resolve the browser rather than pinning a build number that changes under us.
function chromiumPath() {
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH || "/opt/pw-browsers";
  const build = readdirSync(root).filter((name) => name.startsWith("chromium-")).sort().pop();
  if (!build) throw new Error(`no chromium under ${root}`);

  return join(root, build, "chrome-linux", "chrome");
}

const results = {};
const browser = await chromium.launch({ executablePath: chromiumPath() });
const page = await browser.newPage();

try {
  await page.goto(BASE, { waitUntil: "networkidle" });

  // --- the new account screen -------------------------------------------
  await page.click("#generate");
  await page.waitForSelector("#new-account:not(.hidden)");

  results.one_button_on_the_new_account_screen = {
    generate_hidden: await page.locator("#generate").isHidden(),
    submit_label: await page.locator("#unlock").textContent(),
  };

  const rows = page.locator("#new-friends .row");
  results.friend_rows_before_creating = await rows.count();
  results.genesis_named = (await rows.first().locator(".name").textContent()).trim();
  results.genesis_has_an_image = await rows.first().locator("img.avatar").count() > 0;
  results.whole_key_shown = (await rows.first().locator(".pubkey").textContent()).trim();

  // A pasted key gets the generated placeholder, so the list stays consistent.
  const invented = "z".repeat(43);
  await page.fill("#new-friend-key", invented);
  await page.click("#new-friend-add");
  results.friend_rows_after_adding = await rows.count();
  results.added_row_has_a_placeholder =
    await rows.nth(1).locator("span.avatar.placeholder").count() > 0;

  // --- creating the account ---------------------------------------------
  const phrase = await page.inputValue("#new-seed-words");
  await page.fill("#new-name", "Ada");
  await page.fill("#seed", phrase);
  await page.click("#unlock");
  await page.waitForSelector("#chat:not(.hidden)", { timeout: 90_000 });
  results.reached_the_chat = true;

  // --- the friend list, after the account exists ------------------------
  await page.click("#my-profile");
  await page.waitForSelector("#profile:not(.hidden)", { timeout: 10_000 });

  const friends = page.locator("#friend-list .row");
  results.friends_after_creating = await friends.count();
  // The order the friends were chosen in, which survives only because the
  // vault records it: the ratings come back sorted by public key.
  results.friend_order = await friends.locator(".name").allTextContents();
  results.friend_list_shows_an_image = await friends.first().locator("img.avatar").count() > 0;
  results.friend_list_shows_a_whole_key =
    (await friends.first().locator(".pubkey").textContent()).trim().length;
} catch (error) {
  results.error = `${error}`;
} finally {
  await browser.close();
}

console.log(JSON.stringify(results));
