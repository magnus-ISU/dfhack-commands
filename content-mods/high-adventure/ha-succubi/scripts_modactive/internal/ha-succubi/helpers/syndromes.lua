--@module = true

-- Search for the syndrome in the raws, returns nil if not found
function GetSyndrome(synName)
	for _, syn in ipairs(df.global.world.raws.mat_table.syndromes.all) do
		if syn.syn_name == synName then
			return syn
		end
	end
end