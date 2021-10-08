/*
 * Copyright 2021 WebAssembly Community Group participants
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//
// Converts vtables - structs of function references - to use indexes. That is,
// this replaces function reference fields with i32 fields. Specifically,
//
//  (struct (field (ref $functype1)) (field (ref $functype2))
// =>
//  (struct (field (ref i32))        (field (ref i32))
//
// This also creates a table for each field and populates it with the possible
// values. Then struct.news are altered to replace references with indexes, and
// struct.gets are altered to load from the table.
//
// Assumptions:
//  * All function reference fields in structs should be transformed.
//  * Such fields must be written to during creation of a vtable instance, and
//    with a constant ref.func, and never written to with struct.set.
//  * Vtable subtyping is allowed, but not to specialize types of the parent. If
//    that were done, we'd need to add casts to handle the table no having the
//    specialized type (it would have the subtype).
//

#include <ir/module-utils.h>
#include <ir/names.h>
#include <ir/type-updating.h>
#include <ir/utils.h>
#include <pass.h>
#include <wasm-builder.h>
#include <wasm-type.h>
#include <wasm.h>

using namespace std;

namespace wasm {

namespace {

struct VTableToIndexes : public Pass {
  void run(PassRunner* runner, Module* module) override {
    // Map functions written to struct fields to indexes that can be written to
    // them instead. This includes creating the tables and fixing up struct
    // operations to access the tables.
    mapFunctionsToTables(runner, *module);

    // Replace function fields in structs with i32s. This just does the type
    // changes.
    updateFieldTypes(*module);
  }

  void mapFunctionsToTables(PassRunner* runner, Module& wasm) {
    struct MappingInfo {
      // Maps each (struct, field index of a function reference) to the table in
      // which it is declared.
      std::unordered_map<std::pair<HeapType, Index>, Name> fieldTables;

      struct TableInfo {
        // The name of the singleton segment for the table.
        Name segmentName;

        // A map of functions in the table to their indexes.
        std::unordered_map<Name, Index> funcIndexes;
      };

      // Information for all the tables.
      std::unordered_map<Name, TableInfo> tableInfos;
    } mappingInfo;

    struct Mapper : public WalkerPass<PostWalker<Mapper>> {
      // Intentionally *not* function parallel, to make it deterministic, and
      // to not need to lock the mapping info.

      MappingInfo& mapping;

      Mapper(MappingInfo& mapping) : mapping(mapping) {}

      Mapper* create() override { return new Mapper(mapping); }

      void visitStructNew(StructNew* curr) {
        for (Index i = 0; i < curr->operands.size(); i++) {
          auto* operand = curr->operands[i];
          if (!operand->type.isFunction()) {
            continue;
          }

          auto* refFunc = operand->cast<RefFunc>();
          auto heapType = curr->type.getHeapType();
          Index funcIndex;

          auto table = getFieldTable(heapType, i);
          funcIndex = getFuncIndex(table, refFunc->func);

          // Replace the function reference with the proper index.
          curr->operands[i] =
            Builder(*getModule()).makeConst(int32_t(funcIndex));
        }
      }

      void visitStructSet(StructSet* curr) {
        if (curr->value->type.isFunction()) {
          Fatal() << "VTableToIndexes assumes no sets of funcs";
        }
      }

      void visitStructGet(StructGet* curr) {
        if (!curr->type.isFunction()) {
          return;
        }

        Name table;
        Type type;

        table = getFieldTable(curr->ref->type.getHeapType(), curr->index);
        type = getModule()->getTable(table)->type;

        // We now have type i32, as the field will contain an index.
        curr->type = Type::i32;

        replaceCurrent(Builder(*getModule()).makeTableGet(table, curr, type));
      }

      Name getFieldTable(HeapType type, Index i) {
        auto& fieldTable = mapping.fieldTables[{type, i}];
        if (!fieldTable.is()) {
          // Compute the table in which we will store functions for this field.
          // First, find the supertype in which this field was first defined;
          // all subclasses use the same table for their functions.
          // TODO: more memoization here
          HeapType parent = type;
          while (1) {
            HeapType grandParent;
            if (!parent.getSuperType(grandParent)) {
              // No more supers, so parent is the topmost one.
              break;
            }
            if (i >= grandParent.getStruct().fields.size()) {
              // The grand-parent does not have this field, so parent is where
              // it is first defined.
              break;
            }
            // Otherwise, continue up.
            parent = grandParent;
          }

          // We know the proper supertype, and our table is the one it has.
          auto& parentFieldTable = mapping.fieldTables[{parent, i}];
          if (!parentFieldTable.is()) {
            // This is the first time we need a table for this parent; do so
            // now.
            parentFieldTable =
              Names::getValidTableName(*getModule(), "v-table");
            auto fieldType = type.getStruct().fields[i].type;
            if (fieldType.isNonNullable()) {
              // Non-nullable types are not allowed in tables yet.
              fieldType = Type(fieldType.getHeapType(), Nullable);
            }
            getModule()->addTable(
              Builder::makeTable(parentFieldTable, fieldType));
            Name segmentName = Names::getValidElementSegmentName(
              *getModule(), parentFieldTable.str + std::string("$segment"));
            getModule()->addElementSegment(Builder::makeElementSegment(
              segmentName,
              parentFieldTable,
              Builder(*getModule()).makeConst(int32_t(0)),
              fieldType));
            mapping.tableInfos[parentFieldTable].segmentName = segmentName;
          }

          // Copy from the parent;
          fieldTable = parentFieldTable;
        }

        return fieldTable;
      }

      // Returns the index of a function in a table. If not already present
      // there, this allocates a new entry in the table.
      Index getFuncIndex(Name tableName, Name func) {
        auto& tableInfo = mapping.tableInfos[tableName];
        auto& funcIndexes = tableInfo.funcIndexes;
        if (funcIndexes.count(func)) {
          return funcIndexes[func];
        }

        // Enlarge the table, add to the segment, and update the info.
        auto index = funcIndexes.size();
        funcIndexes[func] = index;
        auto* table = getModule()->getTable(tableName);
        table->initial = table->max = index + 1;
        auto* segment = getModule()->getElementSegment(tableInfo.segmentName);
        segment->data.push_back(
          Builder(*getModule())
            .makeRefFunc(func, getModule()->getFunction(func)->type));
        return index;
      }
    };

    Mapper mapper(mappingInfo);
    mapper.run(runner, &wasm);
    mapper.walkModuleCode(&wasm);
  }

  void updateFieldTypes(Module& wasm) {
    class TypeRewriter : public GlobalTypeRewriter {
    public:
      TypeRewriter(Module& wasm) : GlobalTypeRewriter(wasm) {}

      virtual void modifyStruct(HeapType oldStructType, Struct& struct_) {
        auto& oldFields = oldStructType.getStruct().fields;
        auto& newFields = struct_.fields;

        for (Index i = 0; i < oldFields.size(); i++) {
          // Check for function-hood on the old fields, as the new ones contain
          // temp types that we should not be accessing.
          if (oldFields[i].type.isFunction()) {
            // This is exactly what we are looking to change!
            newFields[i].type = Type::i32;
          }
        }
      }
    };

    TypeRewriter(wasm).update();
  }
};

} // anonymous namespace

Pass* createVTableToIndexesPass() { return new VTableToIndexes(); }

} // namespace wasm
