// kashtheking.com links to /library/guides; the section lives under /docs/. Redirect so those links keep working.
import { Redirect } from "@docusaurus/router"
import useBaseUrl from "@docusaurus/useBaseUrl"
import React from "react"

export default function guidesRedirect() {
	return <Redirect to={useBaseUrl("/docs/guides/")} />
}
