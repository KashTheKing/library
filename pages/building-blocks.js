// kashtheking.com links to /library/building-blocks; the section lives under /docs/. Redirect so those links keep working.
import { Redirect } from "@docusaurus/router"
import useBaseUrl from "@docusaurus/useBaseUrl"
import React from "react"

export default function buildingblocksRedirect() {
	return <Redirect to={useBaseUrl("/docs/building-blocks/")} />
}
