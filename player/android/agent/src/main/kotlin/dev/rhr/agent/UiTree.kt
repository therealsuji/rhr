package dev.rhr.agent

import org.json.JSONArray
import org.json.JSONObject

/**
 * One on-screen accessibility node, copied out of AccessibilityNodeInfo so the
 * shaping below is plain code.
 */
internal data class UiNode(
	val className: String?,
	val text: String?,
	val description: String?,
	val viewId: String?,
	val left: Int,
	val top: Int,
	val right: Int,
	val bottom: Int,
	val clickable: Boolean = false,
	val longClickable: Boolean = false,
	val editable: Boolean = false,
	val scrollable: Boolean = false,
	val checkable: Boolean = false,
	val checked: Boolean = false,
	val focused: Boolean = false,
	val enabled: Boolean = true,
	val children: List<UiNode> = emptyList(),
)

/**
 * Shapes a window's nodes for an agent to read: frames normalized to 0–1 of
 * the screen (the same space as a tap), and layout-only wrappers dropped with
 * their meaningful children lifted into their place. A node is meaningful if
 * it says something (text or description) or can be acted on; a view id alone
 * marks a layout container as often as anything an agent needs.
 */
internal object UiTree {
	fun compact(node: UiNode, screenWidth: Int, screenHeight: Int): List<JSONObject> {
		val children = node.children.flatMap { compact(it, screenWidth, screenHeight) }
		val width = node.right - node.left
		val height = node.bottom - node.top
		if (width <= 0 || height <= 0) return children
		val actionable = node.clickable || node.longClickable || node.editable || node.scrollable || node.checkable
		val says = !node.text.isNullOrBlank() || !node.description.isNullOrBlank()
		if (!actionable && !says) return children
		val json = JSONObject()
		node.className?.substringAfterLast('.')?.let { json.put("class", it) }
		node.text?.takeIf { it.isNotBlank() }?.let { json.put("text", it) }
		node.description?.takeIf { it.isNotBlank() && it != node.text }?.let { json.put("description", it) }
		node.viewId?.takeIf { it.isNotBlank() }?.let { json.put("id", it) }
		json.put("frame", JSONArray(listOf(
			fraction(node.left, screenWidth), fraction(node.top, screenHeight),
			fraction(width, screenWidth), fraction(height, screenHeight),
		)))
		val flags = buildList {
			if (node.clickable) add("clickable")
			if (node.longClickable) add("long-clickable")
			if (node.editable) add("editable")
			if (node.scrollable) add("scrollable")
			if (node.checkable) add(if (node.checked) "checked" else "unchecked")
			if (node.focused) add("focused")
			if (!node.enabled) add("disabled")
		}
		if (flags.isNotEmpty()) json.put("flags", JSONArray(flags))
		if (children.isNotEmpty()) json.put("children", JSONArray(children))
		return listOf(json)
	}

	private fun fraction(value: Int, total: Int): Double =
		Math.round(value.toDouble() / total * 1000) / 1000.0
}
