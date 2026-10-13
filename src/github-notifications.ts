#!/usr/bin/env node

import { execFile } from "node:child_process";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";
import { Octokit } from "@octokit/rest";
import nodeNotifier from "node-notifier";

type Notification = Awaited<
	ReturnType<
		Octokit["rest"]["activity"]["listNotificationsForAuthenticatedUser"]
	>
>["data"][number];

type Item = { url: string; repository: string; title: string };
type InboxItem = Item & { key: string; id: string; reason: string };
const exec = promisify(execFile);
const notifier = new nodeNotifier.NotificationCenter({ withFallback: false });
const inbox = "https://github.com/notifications";
const launcher = process.env.SWIFTBAR_PLUGIN_PATH;
const cache =
	process.env.SWIFTBAR_PLUGIN_CACHE_PATH ||
	join(
		homedir(),
		".cache/swiftbar",
		basename(launcher || "github-notifications.3m.sh"),
	);
const icon = Buffer.from(
	'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.11.79-.25.79-.56v-2.14c-3.2.7-3.88-1.36-3.88-1.36-.52-1.33-1.28-1.68-1.28-1.68-1.04-.71.08-.7.08-.7 1.15.08 1.75 1.18 1.75 1.18 1.02 1.75 2.69 1.24 3.34.95.1-.74.4-1.24.73-1.53-2.55-.29-5.23-1.28-5.23-5.69 0-1.25.45-2.28 1.18-3.08-.12-.29-.51-1.46.11-3.04 0 0 .96-.31 3.16 1.18a11 11 0 0 1 5.75 0c2.2-1.49 3.16-1.18 3.16-1.18.62 1.58.23 2.75.11 3.04.73.8 1.18 1.83 1.18 3.08 0 4.42-2.69 5.4-5.25 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.79.56A11.5 11.5 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>',
).toString("base64");

function text(value: unknown) {
	if (typeof value !== "string")
		throw new Error("GitHub returned invalid notification data.");
	return value.replace(/[|\r\n\t]/g, " ");
}

async function token() {
	const value = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
	if (value) return value;
	try {
		const { stdout } = await exec(
			"gh",
			["auth", "token", "--hostname", "github.com"],
			{ timeout: 10000 },
		);
		if (stdout.trim()) return stdout.trim();
	} catch (error) {
		// Child process errors can contain the token, so never surface them.
		if (error instanceof Error && "code" in error && error.code === "ENOENT")
			throw new Error("GitHub CLI (gh) is not installed.");
	}
	throw new Error("Sign in with gh auth login --hostname github.com.");
}

function webURL(notification: Notification) {
	const { subject, repository } = notification;
	if (subject.type === "Release") return `${repository.html_url}/releases`;
	if (!subject.url) return inbox;
	if (!["PullRequest", "Issue", "Discussion", "Commit"].includes(subject.type))
		return inbox;
	const url = new URL(subject.url);
	if (
		url.origin !== "https://api.github.com" ||
		!url.pathname.startsWith("/repos/")
	)
		return inbox;
	return `https://github.com/${url.pathname.slice("/repos/".length).replace("/pulls/", "/pull/").replace("/commits/", "/commit/")}`;
}

async function state(file: string) {
	try {
		return new Set((await readFile(file, "utf8")).split("\n"));
	} catch (error) {
		if (error instanceof Error && "code" in error && error.code === "ENOENT")
			return null;
		throw error;
	}
}

async function save(file: string, values: string[]) {
	const temporary = `${file}.${process.pid}`;
	try {
		await writeFile(temporary, values.length ? `${values.join("\n")}\n` : "", {
			mode: 0o600,
		});
		await rename(temporary, file);
	} finally {
		await rm(temporary, { force: true });
	}
}

function notify(title: string, item: Item, group: string) {
	return new Promise<boolean>((resolve) => {
		const notification = {
			title,
			subtitle: item.repository,
			message: item.title,
			open: item.url,
			sound: "default",
			group,
			timeout: false as const,
		};
		notifier.notify(notification, (error) => resolve(!error));
	});
}

function action(label: string, argument: string) {
	if (!launcher) return `${label} | href=${inbox}`;
	return `${label} | bash="${launcher.replaceAll('"', '\\"')}" param1=${argument} terminal=false`;
}

async function fetchActivity(argument?: string) {
	const github = new Octokit({
		auth: await token(),
		userAgent: "github-notifications-swiftbar",
		request: {
			redirect: "error",
			fetch: (url: RequestInfo | URL, options?: RequestInit) =>
				fetch(url, {
					...options,
					signal: options?.signal
						? AbortSignal.any([options.signal, AbortSignal.timeout(20000)])
						: AbortSignal.timeout(20000),
				}),
		},
		log: { debug() {}, info() {}, warn() {}, error() {} },
	});
	const { data: user } = await github.rest.users.getAuthenticated();
	const requested = await github.paginate(
		github.rest.search.issuesAndPullRequests,
		{
			q: `is:pr is:open archived:false review-requested:${user.login}`,
			per_page: 100,
		},
		(response) => {
			if (response.data.incomplete_results)
				throw new Error("GitHub returned incomplete review search results.");
			if (response.data.total_count > 1000)
				throw new Error(
					"More than 1,000 review requests matched. GitHub search cannot return all of them.",
				);
			return response.data;
		},
	);
	const reviews = requested.map((item) => ({
		url: item.html_url,
		repository: new URL(item.repository_url).pathname.slice("/repos/".length),
		title: `#${item.number} ${text(item.title)}`,
	}));
	if (argument === "open-reviews") return { reviews, notifications: [] };
	const reviewURLs = new Set(reviews.map((item) => item.url));
	const unread = await github.paginate(
		github.rest.activity.listNotificationsForAuthenticatedUser,
		{
			all: false,
			participating: false,
			per_page: 50,
		},
	);
	const notifications = unread
		.map((item) => ({ ...item, url: webURL(item) }))
		.filter(
			(item) => item.reason !== "review_requested" || !reviewURLs.has(item.url),
		)
		.map((item) => ({
			key: `${item.id}:${item.updated_at}`,
			id: item.id,
			repository: text(item.repository.full_name),
			reason: text(item.reason).replaceAll("_", " "),
			title: text(item.subject.title),
			url: item.url,
		}));
	return { reviews, notifications };
}

function renderMenu(reviews: Item[], notifications: InboxItem[]) {
	const total = reviews.length + notifications.length;
	if (!total) return "";

	const menu = [`${total} | templateImage=${icon}`, "---"];
	menu.push(`Review requests (${reviews.length}) | color=gray`);
	if (reviews.length) {
		for (const item of reviews)
			menu.push(`${item.repository} ${item.title} | href=${item.url}`);
		menu.push(action("Open all review requests", "open-reviews"));
	} else {
		menu.push("No reviews requested | color=gray");
	}
	menu.push("---", `Notifications (${notifications.length}) | color=gray`);
	if (notifications.length) {
		for (const item of notifications)
			menu.push(
				`${item.repository} [${item.reason}]: ${item.title} | href=${item.url}`,
			);
		menu.push(action("Open all notifications", "open-notifications"));
	} else {
		menu.push("No unread notifications | color=gray");
	}
	return menu.join("\n");
}

async function deliverAlerts(reviews: Item[], notifications: InboxItem[]) {
	const reviewFile = join(cache, "requested-prs");
	const notificationFile = join(cache, "inbox-notifications");
	const [previousReviews, previousNotifications] = await Promise.all([
		state(reviewFile),
		state(notificationFile),
	]);
	await mkdir(cache, { recursive: true });
	const reviewState = [];
	for (const item of reviews) {
		if (!previousReviews || previousReviews.has(item.url)) {
			reviewState.push(item.url);
			continue;
		}
		if (await notify("Review requested", item, `github-review-${item.url}`))
			reviewState.push(item.url);
	}
	const notificationState = [];
	for (const item of notifications) {
		if (!previousNotifications || previousNotifications.has(item.key)) {
			notificationState.push(item.key);
			continue;
		}
		if (
			await notify(
				`GitHub: ${item.reason}`,
				item,
				`github-notification-${item.id}`,
			)
		)
			notificationState.push(item.key);
	}
	await save(reviewFile, reviewState);
	await save(notificationFile, notificationState);
}

async function main() {
	const argument = process.argv[2];
	if (argument && !["open-reviews", "open-notifications"].includes(argument))
		throw new Error("Usage: github-notifications-swiftbar");
	const { reviews, notifications } = await fetchActivity(argument);
	if (argument) {
		const items = argument === "open-reviews" ? reviews : notifications;
		for (const item of items) await exec("/usr/bin/open", ["-g", item.url]);
		return;
	}

	const menu = renderMenu(reviews, notifications);
	await deliverAlerts(reviews, notifications);
	if (menu) console.log(menu);
}

try {
	await main();
} catch (error) {
	const status =
		error instanceof Error &&
		"status" in error &&
		typeof error.status === "number"
			? error.status
			: null;
	const message =
		status === 401
			? "GitHub authentication expired. Sign in again with gh auth login."
			: status
				? `GitHub request failed (HTTP ${status}). Check token permissions and rate limits.`
				: error instanceof Error
					? error.message
					: "Could not retrieve GitHub notifications.";
	if (process.argv[2]) {
		console.error(message);
		process.exitCode = 1;
	} else {
		console.log(
			`? | color=red templateImage=${icon} href=${inbox}\n---\n${text(message)}`,
		);
	}
}
