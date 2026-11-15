local helpers = require("helpers")
local hover_context = require("django.completions.core.hover_context")

--- Create a scratch buffer with python code
--- @param lines string[]
--- @return number
local function buffer(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

helpers.describe("hover_context", function()
	helpers.it("reads the model out of plain markdown", function()
		local contents = "```python\n(method) def filter(self, *args) -> QuerySet[Post]\n```"

		helpers.eq("Post", hover_context.extract_model(contents))
	end)

	helpers.it("reads the model out of markup contents", function()
		local contents = { kind = "markdown", value = "Manager[Comment]" }

		helpers.eq("Comment", hover_context.extract_model(contents))
	end)

	helpers.it("reads the model out of a contents list", function()
		helpers.eq("Post", hover_context.extract_model({ "QuerySet[Post]" }))
		helpers.eq("Post", hover_context.extract_model({ { value = "QuerySet[Post]" } }))
	end)

	helpers.it("handles values querysets", function()
		helpers.eq("Post", hover_context.extract_model("ValuesQuerySet[Post, dict]"))
	end)

	helpers.it("ignores hovers without a model", function()
		helpers.eq(nil, hover_context.extract_model("(variable) title: str"))
		helpers.eq(nil, hover_context.extract_model(nil))
	end)

	helpers.it("finds the method calls of the current line", function()
		local bufnr = buffer({ "        qs = self.get_queryset().filter(tit" })
		local chain = hover_context.__method_chain(bufnr, 0, #"        qs = self.get_queryset().filter(tit")

		helpers.eq(2, #chain)
		helpers.eq("get_queryset", chain[1].method)
		helpers.eq(0, chain[1].line)
		helpers.eq(18, chain[1].col)
		helpers.eq("filter", chain[2].method)
		helpers.eq(33, chain[2].col)
	end)

	helpers.it("stops at the cursor column", function()
		local code = "Post.objects.filter(title='x').exclude(tit"
		local bufnr = buffer({ code })
		local chain = hover_context.__method_chain(bufnr, 0, #"Post.objects.filter(title='x')")

		helpers.eq(1, #chain)
		helpers.eq("filter", chain[1].method)
	end)

	helpers.it("looks at earlier lines when the current one is empty", function()
		local bufnr = buffer({ "        return Post.objects.all()", "            .filter(tit" })
		local chain = hover_context.__method_chain(bufnr, 1, #"            .filter(tit")

		helpers.eq(1, #chain)
		helpers.eq("filter", chain[1].method)
		helpers.eq(1, chain[1].line)
	end)
end)
