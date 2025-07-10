#!/bin/bash

# GitHub Projects V2 Sync Script
# Syncs GitHub Projects (new project boards) to local markdown files
# Requires: gh CLI with GraphQL support

set -euo pipefail

# Configuration
PROJECT_URL="https://github.com/users/rickbliss/projects/1"
PROJECT_NUMBER="1"
OWNER="rickbliss"
OWNER_TYPE="USER"  # USER or ORGANIZATION
OUTPUT_DIR="docs/project"
BACKLOG_FILE="docs/PROJECT_BACKLOG.md"
KANBAN_FILE="docs/KANBAN.md"
ROADMAP_FILE="docs/ROADMAP.md"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_section() {
    echo -e "${BLUE}[SYNC]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

# GraphQL query to get project data
get_project_data() {
    local query
    if [[ "$OWNER_TYPE" == "USER" ]]; then
        query='query($owner: String!, $number: Int!) {
            user(login: $owner) {
                projectV2(number: $number) {
                    id
                    title
                    url
                    readme
                    shortDescription
                    public
                    closed
                    createdAt
                    updatedAt
                    items(first: 100) {
                        nodes {
                            id
                            type
                            createdAt
                            updatedAt
                            content {
                                ... on Issue {
                                    id
                                    number
                                    title
                                    body
                                    state
                                    url
                                    labels(first: 10) {
                                        nodes {
                                            name
                                            color
                                        }
                                    }
                                    assignees(first: 5) {
                                        nodes {
                                            login
                                        }
                                    }
                                    milestone {
                                        title
                                        dueOn
                                    }
                                    repository {
                                        name
                                        url
                                    }
                                }
                                ... on PullRequest {
                                    id
                                    number
                                    title
                                    body
                                    state
                                    url
                                    labels(first: 10) {
                                        nodes {
                                            name
                                            color
                                        }
                                    }
                                    assignees(first: 5) {
                                        nodes {
                                            login
                                        }
                                    }
                                    repository {
                                        name
                                        url
                                    }
                                }
                                ... on DraftIssue {
                                    id
                                    title
                                    body
                                    createdAt
                                    updatedAt
                                }
                            }
                            fieldValues(first: 20) {
                                nodes {
                                    ... on ProjectV2ItemFieldTextValue {
                                        text
                                        field {
                                            ... on ProjectV2FieldCommon {
                                                name
                                            }
                                        }
                                    }
                                    ... on ProjectV2ItemFieldNumberValue {
                                        number
                                        field {
                                            ... on ProjectV2FieldCommon {
                                                name
                                            }
                                        }
                                    }
                                    ... on ProjectV2ItemFieldSingleSelectValue {
                                        name
                                        field {
                                            ... on ProjectV2FieldCommon {
                                                name
                                            }
                                        }
                                    }
                                    ... on ProjectV2ItemFieldDateValue {
                                        date
                                        field {
                                            ... on ProjectV2FieldCommon {
                                                name
                                            }
                                        }
                                    }
                                    ... on ProjectV2ItemFieldIterationValue {
                                        title
                                        startDate
                                        duration
                                        field {
                                            ... on ProjectV2FieldCommon {
                                                name
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    fields(first: 20) {
                        nodes {
                            ... on ProjectV2Field {
                                id
                                name
                                dataType
                            }
                            ... on ProjectV2SingleSelectField {
                                id
                                name
                                dataType
                                options {
                                    id
                                    name
                                    color
                                }
                            }
                            ... on ProjectV2IterationField {
                                id
                                name
                                dataType
                                configuration {
                                    iterations {
                                        id
                                        title
                                        startDate
                                        duration
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }'
    else
        query='query($owner: String!, $number: Int!) {
            organization(login: $owner) {
                projectV2(number: $number) {
                    # Same structure as above
                }
            }
        }'
    fi
    
    gh api graphql \
        --field owner="$OWNER" \
        --field number="$PROJECT_NUMBER" \
        --raw-field query="$query"
}

# Function to extract field value from item
get_field_value() {
    local item_data="$1"
    local field_name="$2"
    
    echo "$item_data" | jq -r --arg field "$field_name" '
        .fieldValues.nodes[] | 
        select(.field.name == $field) | 
        (.text // .name // .number // .date // .title // "")
    ' 2>/dev/null || echo ""
}

# Function to sync project items
sync_project_items() {
    print_section "Fetching project data..."
    
    local project_data
    project_data=$(get_project_data)
    
    if [[ -z "$project_data" ]] || [[ "$project_data" == "null" ]]; then
        print_error "Failed to fetch project data. Check your permissions and project number."
        exit 1
    fi
    
    # Extract project info
    local project_title project_url project_readme
    project_title=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.title")
    project_url=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.url")
    project_readme=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.readme // \"\"")
    
    print_status "Syncing project: $project_title"
    print_status "Project URL: $project_url"
    
    # Get project fields for understanding the structure
    local fields_data
    fields_data=$(echo "$project_data" | jq ".${OWNER_TYPE,,}.projectV2.fields.nodes")
    
    # Save field definitions
    echo "$fields_data" | jq . > "$OUTPUT_DIR/project_fields.json"
    
    # Process project items
    local items_data
    items_data=$(echo "$project_data" | jq ".${OWNER_TYPE,,}.projectV2.items.nodes")
    
    echo "$items_data" | jq -c '.[]' | while read -r item; do
        local item_type content_type item_id
        item_type=$(echo "$item" | jq -r '.type')
        item_id=$(echo "$item" | jq -r '.id')
        
        if [[ "$item_type" == "ISSUE" ]]; then
            content_type="Issue"
            local number title body state url repo_name
            number=$(echo "$item" | jq -r '.content.number')
            title=$(echo "$item" | jq -r '.content.title')
            body=$(echo "$item" | jq -r '.content.body // "No description"')
            state=$(echo "$item" | jq -r '.content.state')
            url=$(echo "$item" | jq -r '.content.url')
            repo_name=$(echo "$item" | jq -r '.content.repository.name')
            
            # Get project-specific fields
            local status priority assignee iteration due_date
            status=$(get_field_value "$item" "Status")
            priority=$(get_field_value "$item" "Priority")
            assignee=$(echo "$item" | jq -r '.content.assignees.nodes[0].login // "unassigned"')
            iteration=$(get_field_value "$item" "Iteration")
            due_date=$(get_field_value "$item" "Due Date")
            
            # Get labels
            local labels
            labels=$(echo "$item" | jq -r '.content.labels.nodes[].name' | tr '\n' ',' | sed 's/,$//')
            
            # Create filename
            local safe_title filename
            safe_title=$(echo "$title" | tr '/' '-' | tr ' ' '_' | tr -cd '[:alnum:]_-')
            filename="$OUTPUT_DIR/issue_${number}_${safe_title}.md"
            
            # Create markdown file
            cat > "$filename" << EOF
# Issue #${number}: ${title}

**Repository:** ${repo_name}  
**Type:** ${content_type}  
**Status:** ${status:-unknown}  
**State:** ${state}  
**Priority:** ${priority:-none}  
**Assignee:** ${assignee}  
**Iteration:** ${iteration:-none}  
**Due Date:** ${due_date:-none}  
**URL:** ${url}

**Labels:** ${labels:-none}

---

## Description

${body}

---

## Project Fields

- **Status:** ${status:-unset}
- **Priority:** ${priority:-unset}
- **Iteration:** ${iteration:-unset}
- **Due Date:** ${due_date:-unset}

---

*Last synced: $(date)*  
*Project: [${project_title}](${project_url})*
EOF
            
            echo "  ✓ Synced Issue #$number: $title"
            
        elif [[ "$item_type" == "PULL_REQUEST" ]]; then
            content_type="Pull Request"
            local number title body state url repo_name
            number=$(echo "$item" | jq -r '.content.number')
            title=$(echo "$item" | jq -r '.content.title')
            body=$(echo "$item" | jq -r '.content.body // "No description"')
            state=$(echo "$item" | jq -r '.content.state')
            url=$(echo "$item" | jq -r '.content.url')
            repo_name=$(echo "$item" | jq -r '.content.repository.name')
            
            # Get project fields
            local status priority assignee
            status=$(get_field_value "$item" "Status")
            priority=$(get_field_value "$item" "Priority")
            assignee=$(echo "$item" | jq -r '.content.assignees.nodes[0].login // "unassigned"')
            
            # Create filename
            local safe_title filename
            safe_title=$(echo "$title" | tr '/' '-' | tr ' ' '_' | tr -cd '[:alnum:]_-')
            filename="$OUTPUT_DIR/pr_${number}_${safe_title}.md"
            
            cat > "$filename" << EOF
# Pull Request #${number}: ${title}

**Repository:** ${repo_name}  
**Type:** ${content_type}  
**Status:** ${status:-unknown}  
**State:** ${state}  
**Priority:** ${priority:-none}  
**Assignee:** ${assignee}  
**URL:** ${url}

---

## Description

${body}

---

*Last synced: $(date)*  
*Project: [${project_title}](${project_url})*
EOF
            
            echo "  ✓ Synced PR #$number: $title"
            
        elif [[ "$item_type" == "DRAFT_ISSUE" ]]; then
            content_type="Draft Issue"
            local title body created_at
            title=$(echo "$item" | jq -r '.content.title')
            body=$(echo "$item" | jq -r '.content.body // "No description"')
            created_at=$(echo "$item" | jq -r '.content.createdAt')
            
            # Get project fields
            local status priority
            status=$(get_field_value "$item" "Status")
            priority=$(get_field_value "$item" "Priority")
            
            # Create filename
            local safe_title filename
            safe_title=$(echo "$title" | tr '/' '-' | tr ' ' '_' | tr -cd '[:alnum:]_-')
            filename="$OUTPUT_DIR/draft_${safe_title}.md"
            
            cat > "$filename" << EOF
# Draft Issue: ${title}

**Type:** ${content_type}  
**Status:** ${status:-unknown}  
**Priority:** ${priority:-none}  
**Created:** ${created_at}

---

## Description

${body}

---

*Last synced: $(date)*  
*Project: [${project_title}](${project_url})*
EOF
            
            echo "  ✓ Synced Draft: $title"
        fi
    done
}

# Function to create project backlog
create_project_backlog() {
    print_section "Creating project backlog..."
    
    local project_data items_data
    project_data=$(get_project_data)
    items_data=$(echo "$project_data" | jq ".${OWNER_TYPE,,}.projectV2.items.nodes")
    
    local project_title project_url
    project_title=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.title")
    project_url=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.url")
    
    cat > "$BACKLOG_FILE" << EOF
# ${project_title} - Project Backlog

**Project:** [${project_title}](${project_url})  
**Last Updated:** $(date)

---

## 🔥 High Priority Items

EOF
    
    # Add high priority items
    echo "$items_data" | jq -c '.[]' | while read -r item; do
        local priority=$(get_field_value "$item" "Priority")
        local status=$(get_field_value "$item" "Status")
        local item_type=$(echo "$item" | jq -r '.type')
        
        if [[ "$priority" == "High" ]] || [[ "$priority" == "🔥 High" ]]; then
            if [[ "$item_type" == "ISSUE" ]]; then
                local number title url
                number=$(echo "$item" | jq -r '.content.number')
                title=$(echo "$item" | jq -r '.content.title')
                url=$(echo "$item" | jq -r '.content.url')
                echo "- [#${number}](${url}) ${title} - **Status:** ${status}" >> "$BACKLOG_FILE"
            elif [[ "$item_type" == "DRAFT_ISSUE" ]]; then
                local title
                title=$(echo "$item" | jq -r '.content.title')
                echo "- [Draft] ${title} - **Status:** ${status}" >> "$BACKLOG_FILE"
            fi
        fi
    done
    
    cat >> "$BACKLOG_FILE" << EOF

## 📋 Medium Priority Items

EOF
    
    # Add medium priority items
    echo "$items_data" | jq -c '.[]' | while read -r item; do
        local priority=$(get_field_value "$item" "Priority")
        local status=$(get_field_value "$item" "Status")
        local item_type=$(echo "$item" | jq -r '.type')
        
        if [[ "$priority" == "Medium" ]] || [[ "$priority" == "📋 Medium" ]]; then
            if [[ "$item_type" == "ISSUE" ]]; then
                local number title url
                number=$(echo "$item" | jq -r '.content.number')
                title=$(echo "$item" | jq -r '.content.title')
                url=$(echo "$item" | jq -r '.content.url')
                echo "- [#${number}](${url}) ${title} - **Status:** ${status}" >> "$BACKLOG_FILE"
            elif [[ "$item_type" == "DRAFT_ISSUE" ]]; then
                local title
                title=$(echo "$item" | jq -r '.content.title')
                echo "- [Draft] ${title} - **Status:** ${status}" >> "$BACKLOG_FILE"
            fi
        fi
    done
    
    cat >> "$BACKLOG_FILE" << EOF

---

*Generated from GitHub Projects API*
EOF
}

# Function to create Kanban board view
create_kanban_view() {
    print_section "Creating Kanban board view..."
    
    local project_data items_data
    project_data=$(get_project_data)
    items_data=$(echo "$project_data" | jq ".${OWNER_TYPE,,}.projectV2.items.nodes")
    
    local project_title project_url
    project_title=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.title")
    project_url=$(echo "$project_data" | jq -r ".${OWNER_TYPE,,}.projectV2.url")
    
    cat > "$KANBAN_FILE" << EOF
# ${project_title} - Kanban Board

**Project:** [${project_title}](${project_url})  
**Last Updated:** $(date)

---

## 📝 Todo

EOF
    
    # Todo items
    echo "$items_data" | jq -c '.[]' | while read -r item; do
        local status=$(get_field_value "$item" "Status")
        local item_type=$(echo "$item" | jq -r '.type')
        
        if [[ "$status" == "Todo" ]] || [[ "$status" == "📝 Todo" ]] || [[ "$status" == "Backlog" ]]; then
            if [[ "$item_type" == "ISSUE" ]]; then
                local number title url priority
                number=$(echo "$item" | jq -r '.content.number')
                title=$(echo "$item" | jq -r '.content.title')
                url=$(echo "$item" | jq -r '.content.url')
                priority=$(get_field_value "$item" "Priority")
                echo "- [#${number}](${url}) ${title} ${priority:+(**${priority}**)}" >> "$KANBAN_FILE"
            elif [[ "$item_type" == "DRAFT_ISSUE" ]]; then
                local title priority
                title=$(echo "$item" | jq -r '.content.title')
                priority=$(get_field_value "$item" "Priority")
                echo "- [Draft] ${title} ${priority:+(**${priority}**)}" >> "$KANBAN_FILE"
            fi
        fi
    done
    
    cat >> "$KANBAN_FILE" << EOF

## 🚧 In Progress

EOF
    
    # In Progress items
    echo "$items_data" | jq -c '.[]' | while read -r item; do
        local status=$(get_field_value "$item" "Status")
        local item_type=$(echo "$item" | jq -r '.type')
        
        if [[ "$status" == "In Progress" ]] || [[ "$status" == "🚧 In Progress" ]]; then
            if [[ "$item_type" == "ISSUE" ]]; then
                local number title url assignee
                number=$(echo "$item" | jq -r '.content.number')
                title=$(echo "$item" | jq -r '.content.title')
                url=$(echo "$item" | jq -r '.content.url')
                assignee=$(echo "$item" | jq -r '.content.assignees.nodes[0].login // "unassigned"')
                echo "- [#${number}](${url}) ${title} - **@${assignee}**" >> "$KANBAN_FILE"
            fi
        fi
    done
    
    cat >> "$KANBAN_FILE" << EOF

## ✅ Done

EOF
    
    # Done items
    echo "$items_data" | jq -c '.[]' | while read -r item; do
        local status=$(get_field_value "$item" "Status")
        local item_type=$(echo "$item" | jq -r '.type')
        
        if [[ "$status" == "Done" ]] || [[ "$status" == "✅ Done" ]]; then
            if [[ "$item_type" == "ISSUE" ]]; then
                local number title url
                number=$(echo "$item" | jq -r '.content.number')
                title=$(echo "$item" | jq -r '.content.title')
                url=$(echo "$item" | jq -r '.content.url')
                echo "- [#${number}](${url}) ${title}" >> "$KANBAN_FILE"
            fi
        fi
    done
    
    cat >> "$KANBAN_FILE" << EOF

---

*Generated from GitHub Projects API*
EOF
}

# Main execution
main() {
    print_status "Starting GitHub Projects sync..."
    print_status "Project: $PROJECT_URL"
    
    # Check dependencies
    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI (gh) is not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed"
        exit 1
    fi
    
    if ! gh auth status &> /dev/null; then
        print_error "Not logged in to GitHub CLI. Run: gh auth login"
        exit 1
    fi
    
    # Sync project items
    sync_project_items
    
    # Create different views
    create_project_backlog
    create_kanban_view
    
    print_status "✅ Project sync completed!"
    print_status "📁 Project items: $OUTPUT_DIR"
    print_status "📋 Backlog: $BACKLOG_FILE"
    print_status "📊 Kanban: $KANBAN_FILE"
    
    # Show summary
    local total_items
    total_items=$(find "$OUTPUT_DIR" -name "*.md" | wc -l)
    echo ""
    echo "📊 Summary:"
    echo "   Total items synced: $total_items"
    echo "   Individual files: $OUTPUT_DIR/"
    echo "   Backlog view: $BACKLOG_FILE"
    echo "   Kanban view: $KANBAN_FILE"
}

main "$@"