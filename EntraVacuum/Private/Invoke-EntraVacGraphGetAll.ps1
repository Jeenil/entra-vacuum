function Invoke-EntraVacGraphGetAll {
    <#
    .SYNOPSIS
        GETs a Graph collection and follows @odata.nextLink until every page is read.

    .PARAMETER Uri
        Absolute Graph URI of the collection.

    .PARAMETER Headers
        Optional request headers, for example ConsistencyLevel = eventual.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Uri,

        [hashtable] $Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next  = $Uri
    while ($next) {
        $page = if ($Headers) {
            Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers -ErrorAction Stop
        } else {
            Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        }
        if ($page.value) { $items.AddRange(@($page.value)) }
        $next = $page.'@odata.nextLink'
    }
    $items
}
