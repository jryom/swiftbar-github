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

type Item = {
	url: string;
	repository: string;
	title: string;
	key: string;
	group: string;
	alertTitle: string;
	label: string;
};
type Section = {
	title: string;
	empty: string;
	action: string;
	state: string;
	items: Item[];
};
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
const icon = (
	await readFile(new URL("../assets/github.svg", import.meta.url))
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

function notify(item: Item) {
	return new Promise<boolean>((resolve) => {
		const notification = {
			title: item.alertTitle,
			subtitle: item.repository,
			message: item.title,
			open: item.url,
			sound: "default",
			group: item.group,
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
	const reviews = requested.map((item) => {
		const repository = new URL(item.repository_url).pathname.slice(
			"/repos/".length,
		);
		const title = `#${item.number} ${text(item.title)}`;
		return {
			url: item.html_url,
			repository,
			title,
			key: item.html_url,
			group: `github-review-${item.html_url}`,
			alertTitle: "Review requested",
			label: `${repository} ${title}`,
		};
	});
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
		.map((item) => {
			const repository = text(item.repository.full_name);
			const reason = text(item.reason).replaceAll("_", " ");
			const title = text(item.subject.title);
			return {
				key: `${item.id}:${item.updated_at}`,
				repository,
				title,
				url: item.url,
				group: `github-notification-${item.id}`,
				alertTitle: `GitHub: ${reason}`,
				label: `${repository} [${reason}]: ${title}`,
			};
		});
	return { reviews, notifications };
}

function renderMenu(sections: Section[]) {
	const total = sections.reduce(
		(count, section) => count + section.items.length,
		0,
	);
	if (!total) return "";

	const menu = [`${total} | templateImage=${icon}`];
	for (const section of sections) {
		menu.push("---", `${section.title} (${section.items.length}) | color=gray`);
		if (section.items.length) {
			for (const item of section.items)
				menu.push(`${item.label} | href=${item.url}`);
			menu.push(
				action(`Open all ${section.title.toLowerCase()}`, section.action),
			);
		} else menu.push(`${section.empty} | color=gray`);
	}
	return menu.join("\n");
}

async function deliverAlerts(sections: Section[]) {
	await mkdir(cache, { recursive: true });
	const previous = await Promise.all(
		sections.map((section) => state(join(cache, section.state))),
	);
	for (const [index, section] of sections.entries()) {
		const seen = previous[index];
		const current = [];
		for (const item of section.items) {
			if (!seen || seen.has(item.key) || (await notify(item)))
				current.push(item.key);
		}
		await save(join(cache, section.state), current);
	}
}

async function main() {
	const argument = process.argv[2];
	if (argument && !["open-reviews", "open-notifications"].includes(argument))
		throw new Error("Usage: github-notifications-swiftbar");
	const { reviews, notifications } = await fetchActivity(argument);
	const sections = [
		{
			title: "Review requests",
			empty: "No reviews requested",
			action: "open-reviews",
			state: "requested-prs",
			items: reviews,
		},
		{
			title: "Notifications",
			empty: "No unread notifications",
			action: "open-notifications",
			state: "inbox-notifications",
			items: notifications,
		},
	];
	if (argument) {
		const items =
			sections.find((section) => section.action === argument)?.items || [];
		for (const item of items) await exec("/usr/bin/open", ["-g", item.url]);
		return;
	}

	const menu = renderMenu(sections);
	await deliverAlerts(sections);
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
