import Link from "@docusaurus/Link"
import useDocusaurusContext from "@docusaurus/useDocusaurusContext"
import CodeBlock from "@theme/CodeBlock"
import Layout from "@theme/Layout"
import React from "react"
import styles from "./index.module.css"

const SECTIONS = [
	{
		title: "Packages",
		to: "/docs/packages/",
		meta: "15 Wally packages",
		text: "Binder, Packet, Hitbox, CameraController, GuiHandler, t and more. Install with Wally or the Studio Wally plugin, every one with a generated API reference.",
	},
	{
		title: "Plugins",
		to: "/docs/plugins/",
		meta: "7 Studio plugins",
		text: "Packager, Studio Wally, Bounding Box, Init Framework, Infinite Ocean, Flashback and the upcoming Viewmodel Editor. One click from the Creator Store.",
	},
	{
		title: "Building Blocks",
		to: "/docs/building-blocks/",
		meta: "ready-made systems",
		text: "Fully built systems as .rbxm files. Download, unpack with Packager, and they are in your experience with their dependencies.",
	},
	{
		title: "Guides",
		to: "/docs/guides/",
		meta: "how I build games",
		text: "Installing packages, structuring a game around Binder components, contributing to the library, and full game walkthroughs.",
	},
]

const FEATURES = [
	{
		title: "One repository, one site",
		text: "Every package, plugin, block and guide lives in github.com/KashTheKing/library. Each page here links to its source, and every API entry links to the exact line of code.",
	},
	{
		title: "Typed and strict",
		text: "Packages are written in strict Luau and export their types. Studio Wally re-exports them, so autocomplete works the moment you require a module.",
	},
	{
		title: "Cleanup built in",
		text: "Most packages hand you a Trove and clean it for you when an instance leaves, a state exits or a hitbox is destroyed. No leaked connections.",
	},
	{
		title: "Free and MIT",
		text: "Packages and building blocks are MIT licensed. Use them in anything, commercial or not. Plugins are on the Creator Store, most of them free.",
	},
]

const SAMPLE = `local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Binder = require(ReplicatedStorage.Packages.Binder)

-- A class for every part tagged "Door"
local Door = {}
Door.__index = Door

function Door.new(part: BasePart, trove)
	local self = setmetatable({ Part = part, Open = false }, Door)
	trove:Connect(part.ClickDetector.MouseClick, function()
		self.Open = not self.Open
		part.Transparency = if self.Open then 0.8 else 0
	end)
	return self
end

-- Bind it: constructed on add, Trove cleaned on remove
Binder.new(Door, {
	Tags = { "Door" },
	ClassNames = { "BasePart" },
	AutoStart = true,
})`

function Section({ title, to, meta, text }) {
	return (
		<Link className={styles.section} to={to}>
			<span className={styles.sectionMeta}>{meta}</span>
			<h3>{title}</h3>
			<p>{text}</p>
			<span className={styles.sectionCta}>Open →</span>
		</Link>
	)
}

function Feature({ title, text }) {
	return (
		<div className={styles.feature}>
			<h3>{title}</h3>
			<p>{text}</p>
		</div>
	)
}

export default function Home() {
	const { siteConfig } = useDocusaurusContext()
	return (
		<Layout title={siteConfig.title} description={siteConfig.tagline}>
			<header className={styles.hero}>
				<div className={styles.heroInner}>
					<h1 className={styles.title}>KashTheKing's Library</h1>
					<p className={styles.tagline}>{siteConfig.tagline}</p>
					<div className={styles.buttons}>
						<Link className="button button--primary button--lg" to="/docs/intro/">
							Get started
						</Link>
						<Link className="button button--outline button--lg" to="/api/">
							API reference
						</Link>
						<Link className="button button--outline button--lg" href="https://github.com/KashTheKing/library">
							GitHub
						</Link>
					</div>
				</div>
			</header>
			<main className={styles.main}>
				<section className={styles.sections}>
					{SECTIONS.map((s) => (
						<Section key={s.title} {...s} />
					))}
				</section>
				<section className={styles.split}>
					<div>
						<h2>Tag it, bind it, forget the cleanup</h2>
						<p>
							Most of my games are built the same way: an instance gets a tag, Binder constructs a class for it and
							hands over a Trove, and when the instance leaves the Trove is cleaned. Networking, hitboxes, cameras
							and UI in the library follow the same rule: one object, one Destroy.
						</p>
						<Link to="/docs/guides/components-with-binder/">Components with Binder guide →</Link>
					</div>
					<CodeBlock language="lua">{SAMPLE}</CodeBlock>
				</section>
				<section className={styles.features}>
					{FEATURES.map((f) => (
						<Feature key={f.title} {...f} />
					))}
				</section>
				<section className={styles.cta}>
					<h2>Made by KashTheKing</h2>
					<p>
						Help, bug reports and feedback: the <strong>Discord</strong>, a GitHub issue, or{" "}
						<a href="mailto:kashtheking123@gmail.com">kashtheking123@gmail.com</a>. Find me as{" "}
						<strong>@KashTheKing</strong> on Roblox, X and YouTube.
					</p>
					<div className={styles.buttons}>
						<Link className="button button--primary button--md" href="https://discord.gg/6HYgCk22eD">
							Join the Discord
						</Link>
						<Link className="button button--outline button--md" href="https://github.com/KashTheKing/library/issues">
							Report an issue
						</Link>
						<Link className="button button--outline button--md" to="/docs/support/">
							All contact details
						</Link>
					</div>
				</section>
			</main>
		</Layout>
	)
}
