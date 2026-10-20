import { createFileRoute, Link } from "@tanstack/react-router";
import { ArrowLeft, ArrowUpRight, Code2, Palette, Layers, Map } from "lucide-react";
import { Button } from "@/components/ui/button";
import { OrionLogo } from "@/components/orion/OrionLogo";
import { SiteFooter } from "@/components/orion/LegalPage";

const url = "https://orion-stellar-ai.lovable.app/blog/ai-tools-for-game-development";
const title = "Top AI Tools for Game Development: An Indie Developer Guide";
const description = "Compare GitHub Copilot, Adobe Firefly, Scenario and Ludo.ai for game programming, art and level planning, with practical indie development workflows.";

const tools = [
  {
    name: "GitHub Copilot", category: "Programming", icon: Code2, id: "copilot",
    best: "Gameplay code, explanations and test drafts", output: "Code suggestions in supported IDEs", limit: "Review engine APIs and test every change",
    intro: "Choose Copilot when the bottleneck is understanding or changing code. It offers code suggestions and chat in supported development environments, including help explaining code, drafting tests and suggesting fixes. It is an assistant inside your coding workflow, not a game engine or a substitute for debugging.",
    steps: ["Select one small task, such as adding a cooldown to an existing player ability. Give the assistant the relevant script, your engine version and the expected behavior.", "Ask for the smallest change and an explanation of how it affects the current code. Avoid asking it to rebuild the entire game.", "Review the diff, compile in your engine, and test repeated input, scene reloads and missing references. Ask for test cases for the failures you actually observe."],
    prompt: "In this existing ability script, add a cooldown without changing movement. Explain the engine APIs you use and propose tests for repeated input and scene reloads.",
    caveat: "IDE support and available features vary. Generated code can be incorrect or resemble public code; check code references, licensing requirements and your organization's privacy settings before sharing a private repository.",
    source: "https://docs.github.com/en/copilot/get-started/features", extra: "https://docs.github.com/en/copilot/concepts/copilot-surfaces/copilot-in-ides",
  },
  {
    name: "Adobe Firefly", category: "Art direction", icon: Palette, id: "firefly",
    best: "Moodboards and visual concept variations", output: "Images for visual exploration", limit: "Concept art is not a production-ready asset",
    intro: "Choose Firefly to explore an art direction before investing in final assets. Adobe describes game-development uses such as visual concepts and iteration. For a small team, its most useful role is making different character, environment or background directions concrete enough to compare.",
    steps: ["Write a visual brief with the camera angle, palette, silhouette, environment and intended screen size. Keep those constraints consistent between variations.", "Generate a few alternatives for one scene or character. Compare readability and fit with your existing art, not just how impressive each image looks.", "Use the selected direction as a reference for production. Prepare dimensions, transparency, collision shapes and animation separately in your normal asset workflow."],
    prompt: "Explore three visual directions for a side-view forest checkpoint in a small 2D game. Keep the player path readable and separate foreground props from the background.",
    caveat: "An attractive image does not guarantee usable sprites, seamless textures or consistent animation frames. Check the terms of the specific Adobe feature and model before commercial use; do not assume every model has the same conditions.",
    source: "https://www.adobe.com/products/firefly/discover/ai-for-game-developers.html", extra: "https://www.adobe.com/legal/terms.html",
  },
  {
    name: "Scenario", category: "Asset workflows", icon: Layers, id: "scenario",
    best: "Style-aligned assets and repeatable generation", output: "Asset candidates and API workflows", limit: "Rights to references and output cleanup matter",
    intro: "Choose Scenario when you need repeated asset exploration within a defined visual style. It offers asset-generation tools and custom model training on reference material, as well as an API for integrating generation into a pipeline. That makes it a different fit from a one-off moodboard generator.",
    steps: ["Start with an art bible and references you have permission to use. Define what must stay consistent: perspective, lighting, proportions and material detail.", "Generate a small family of props, such as a crate, chest and door. Compare the set together before expanding to dozens of assets.", "Inspect edges, dimensions, textures and visual consistency in the engine. Only automate a larger batch after your manual import and quality checks work."],
    prompt: "Create concept variations for three props in the same game environment: a crate, a chest and a door. Match the approved reference style, perspective and lighting.",
    caveat: "An API is not a guaranteed native integration for every engine or asset format. Inspect exports and check current commercial-use, model and training-data terms. Do not upload confidential or third-party references without permission.",
    source: "https://www.scenario.com/features", extra: "https://www.scenario.com/terms-and-conditions",
  },
  {
    name: "Ludo.ai", category: "Design and level planning", icon: Map, id: "ludo",
    best: "Mechanics, game concepts and design documents", output: "Design ideas and prototype asset candidates", limit: "Planning is not automatic playable level creation",
    intro: "Choose Ludo.ai when you need to turn a vague concept into a structured game idea. Its documented tools cover ideation, project organization and asset creation, with a Unity plugin available. For level design, treat it as a brainstorming and documentation aid rather than an automatic builder of balanced, playable levels.",
    steps: ["Define the player action, target session length and one mechanic to teach. Ask for a progression of situations, not a complete world.", "Select a sequence with an introduction, a safe practice area and a harder combination. Convert it into a simple level brief with explicit constraints.", "Build a graybox in your engine. Playtest route clarity, timing and difficulty; revise the layout using observed player behavior rather than accepting the generated plan."],
    prompt: "Outline a short beginner platforming level that teaches a dash: safe introduction, practice, then one combined challenge. Include checkpoints and likely confusion points; do not invent exact jump distances.",
    caveat: "Verify the Unity plugin's current version requirements. Support documented for Unity should not be assumed for Godot or Unreal. Generated ideas still need originality checks, and assets need licensing and import review.",
    source: "https://ludo.ai/features", extra: "https://ludo.ai/unity-plugin",
  },
];

export const Route = createFileRoute("/blog/ai-tools-for-game-development")({
  head: () => ({
    meta: [
      { title: `${title} — Orión Estellar` },
      { name: "description", content: description },
      { property: "og:title", content: title },
      { property: "og:description", content: description },
      { property: "og:type", content: "article" },
      { property: "og:url", content: url },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [{ rel: "canonical", href: url }],
    scripts: [{ type: "application/ld+json", children: JSON.stringify({
      "@context": "https://schema.org", "@graph": [
        { "@type": "Article", headline: title, description, mainEntityOfPage: url, inLanguage: "en", author: { "@type": "Organization", name: "Orión Estellar", url: "https://orion-stellar-ai.lovable.app" } },
        { "@type": "BreadcrumbList", itemListElement: [
          { "@type": "ListItem", position: 1, name: "Orión Estellar", item: "https://orion-stellar-ai.lovable.app" },
          { "@type": "ListItem", position: 2, name: title, item: url },
        ] },
      ],
    }) }],
  }),
  component: GuidePage,
});

function GuidePage() {
  return (
    <div className="min-h-screen bg-background text-foreground" lang="en">
      <header className="border-b border-border">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-3 px-5 py-4">
          <Link to="/" className="flex items-center gap-3 font-semibold"><OrionLogo size={32} />Orión Estellar</Link>
          <Button asChild variant="outline" className="btn-glass"><Link to="/"><ArrowLeft />Open chat</Link></Button>
        </div>
      </header>
      <main className="mx-auto max-w-5xl px-5 py-10 md:py-14">
        <article>
          <div className="max-w-3xl space-y-5">
            <p className="text-sm font-medium text-primary">Indie development · Practical guide</p>
            <h1 className="text-3xl font-semibold leading-tight md:text-4xl">Top AI Tools for Game Development</h1>
            <p className="text-lg leading-relaxed text-muted-foreground">How to choose and use AI for programming, art generation and level design—without handing over creative control.</p>
            <p className="leading-relaxed">The best AI tools for game development depend on the task you need to finish. Start with <strong>GitHub Copilot for code</strong>, <strong>Adobe Firefly for visual exploration</strong>, <strong>Scenario for repeatable asset workflows</strong> or <strong>Ludo.ai for design planning</strong>. Build one small, playable scene before expanding your tool stack.</p>
            <p className="text-sm leading-relaxed text-muted-foreground">By Orión Estellar. This is a curated, documentation-based comparison, not a hands-on benchmark or a universal ranking. Selection favors a clear indie use case, documented capabilities and a workflow you can validate yourself. Features and terms can change; official sources are linked below. Example prompts are starting points, not tested guarantees.</p>
          </div>

          <nav aria-label="Guide contents" className="my-8 flex flex-wrap gap-x-6 gap-y-3 border-y border-border py-4 text-sm">
            <a href="#comparison" className="text-primary underline underline-offset-4">Compare tools</a>
            {tools.map(tool => <a key={tool.id} href={`#${tool.id}`} className="hover:text-primary underline underline-offset-4">{tool.name}</a>)}
            <a href="#workflow" className="text-primary underline underline-offset-4">Build a playable scene</a>
          </nav>

          <section id="comparison" className="scroll-mt-6 space-y-4">
            <h2 className="text-2xl font-semibold">Which AI tool fits your workflow?</h2>
            <p className="max-w-3xl leading-relaxed">Use this comparison to pick one bottleneck. No tool listed here replaces engine knowledge, asset preparation or player testing.</p>
            <div className="overflow-x-auto rounded-lg border border-border" tabIndex={0} aria-label="AI tool comparison table">
              <table className="w-full min-w-[700px] text-left text-sm">
                <caption className="sr-only">AI game development tools compared by use case, output and limitation</caption>
                <thead className="bg-muted"><tr>{["Tool", "Best use case", "What you get", "Main check"].map(label => <th key={label} scope="col" className="px-4 py-3 font-semibold">{label}</th>)}</tr></thead>
                <tbody>{tools.map(tool => <tr key={tool.id} className="border-t border-border"><th scope="row" className="px-4 py-4"><a href={`#${tool.id}`} className="text-primary underline">{tool.name}</a></th><td className="px-4 py-4">{tool.best}</td><td className="px-4 py-4">{tool.output}</td><td className="px-4 py-4">{tool.limit}</td></tr>)}</tbody>
              </table>
            </div>
            <p className="text-sm text-muted-foreground">Pricing is not compared here: subscriptions, credits and model access change. Check each provider's current plan and usage conditions before committing.</p>
          </section>

          {tools.map((tool, index) => <section key={tool.id} id={tool.id} className="mt-10 scroll-mt-6 border-t border-border pt-8">
            <div className="mb-4 flex items-start gap-3"><tool.icon className="mt-1 h-6 w-6 shrink-0 text-primary" aria-hidden="true" /><div><p className="mb-1 text-sm text-muted-foreground">{tool.category}</p><h2 className="text-2xl font-semibold">{index + 1}. {tool.name}</h2></div></div>
            <div className="max-w-3xl space-y-5 leading-relaxed">
              <p>{tool.intro}</p>
              <h3 className="text-lg font-semibold">How to use it in an indie project</h3>
              <ol className="list-decimal space-y-3 pl-6">{tool.steps.map(step => <li key={step}>{step}</li>)}</ol>
              <blockquote className="border-l-2 border-primary bg-muted px-5 py-4"><p className="mb-2 text-xs font-semibold text-primary">Example prompt</p><p>{tool.prompt}</p></blockquote>
              <p><strong>Watch out for: </strong>{tool.caveat}</p>
              <div className="flex flex-wrap gap-x-5 gap-y-2 text-sm"><a href={tool.source} className="inline-flex items-center gap-1 text-primary underline underline-offset-4">Official features<ArrowUpRight className="h-4 w-4" /></a><a href={tool.extra} className="text-primary underline underline-offset-4">Documentation and conditions</a></div>
            </div>
          </section>)}

          <section id="workflow" className="mt-10 max-w-3xl scroll-mt-6 space-y-5 border-t border-border pt-8 leading-relaxed">
            <h2 className="text-2xl font-semibold">How to use AI for game development: one playable scene</h2>
            <p>A useful first experiment is a single room with one ability, one obstacle and one goal. Keep the scope small enough to test manually.</p>
            <ol className="list-decimal space-y-3 pl-6">
              <li><strong>Write the brief.</strong> Define your engine version, controls, target device and success condition. Use Ludo.ai for design alternatives if you are stuck, then select one yourself.</li>
              <li><strong>Graybox before generating final art.</strong> Place simple shapes in the engine and check movement, camera framing and collision. For level design, real player movement matters more than a persuasive written layout.</li>
              <li><strong>Implement one mechanic.</strong> Use Copilot to propose a small change to existing code. Review and test it before adding another system.</li>
              <li><strong>Choose a visual direction.</strong> Explore concepts in Firefly; consider Scenario when you need a consistent family of assets. Keep placeholders until the scene is fun.</li>
              <li><strong>Prepare and import assets.</strong> Check scale, texture size, transparency, animation needs and performance on your target device. A generated picture cannot supply collision logic or gameplay balance.</li>
              <li><strong>Playtest and record decisions.</strong> Note where players hesitate or fail. Revise the level and keep the reason for each change. Keep a record of asset sources, permissions and applicable terms before release.</li>
            </ol>
            <h3 className="text-lg font-semibold">Where Orión Estellar fits</h3>
            <p>Orión is a conversational workspace for discussing programming questions, art ideas and level briefs. You can keep project notes and ask for explanations or alternatives. Verify generated advice in your engine. The web app and the Builda edition have different capabilities: Builda uses a small bundled local chat model, while web-dependent tools require the web version. Orión does not control your device or automatically build and publish a finished game.</p>
            <Button asChild className="btn-cosmic"><Link to="/">Open Orión Estellar<ArrowUpRight /></Link></Button>
          </section>

          <section className="mt-10 max-w-3xl space-y-4 border-t border-border pt-8 leading-relaxed">
            <h2 className="text-2xl font-semibold">Before you ship</h2>
            <p>Choose tools by engine compatibility, input privacy, commercial-use conditions and the work required to clean up output. A free trial is not proof of a commercial license, and a provider's ownership statement is not a guarantee that every generated asset is unique or free of third-party rights.</p>
            <p>Do not upload private code, unreleased art or player information without permission. Check the current requirements of your storefront and publisher. Keep human review, testing and creative decisions in the process: that is what turns a collection of generated outputs into a coherent game.</p>
          </section>
        </article>
      </main>
      <SiteFooter />
    </div>
  );
}